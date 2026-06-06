#!/usr/bin/env ruby
# frozen_string_literal: true

# Storage format benchmark for igniter-ledger.
#
# Measures write throughput, read throughput, and bytes/fact for four codec
# strategies across three data profiles drawn from the CRM/dispatch domain.
#
# Usage:
#   gem install msgpack          # optional but unlocks 3 of 4 codecs
#   bundle exec ruby packages/igniter-ledger/bench/storage_formats.rb
#   bundle exec ruby packages/igniter-ledger/bench/storage_formats.rb --profile gps_stream --facts 20000
#   bundle exec ruby packages/igniter-ledger/bench/storage_formats.rb --json

require "json"
require "zlib"
require "digest"
require "securerandom"
require "tmpdir"
require "fileutils"
require "optparse"

MSGPACK_AVAILABLE = begin
  require "msgpack"
  true
rescue LoadError
  warn "[bench] msgpack gem not available — only json_crc32 codec will run."
  warn "        gem install msgpack   to unlock the other codecs."
  false
end

# ── Profiles ──────────────────────────────────────────────────────────────────
#
# Three realistic write profiles from the CRM / dispatch context.
#
# GPS_STREAM   — technician geolocation updates, small homogeneous payload,
#                high repetition of field names and key strings.
# LEAD_SIGNALS — vendor lead signals arriving at ~2k RPM, richer payload,
#                more key diversity.
# MIXED        — 70 % GPS + 20 % leads + 10 % CRM job records, reflects
#                a production igniter-ledger instance.

module Profiles
  GPS_STREAM = {
    name: "gps_stream",
    desc: "Technician GPS updates — 200 technicians, small homogeneous payload",
    gen: ->(i) {
      tech = "tech_#{(i % 200) + 1}"
      { store: :technician_locations, key: tech, value: {
        technician_id: tech,
        lat:           33.9000 + (i % 100) * 0.001,
        lng:           -118.2000 + (i % 100) * 0.001,
        accuracy_m:    (5 + i % 20).to_f,
        battery_pct:   80 - i % 30,
        recorded_at:   1_746_182_400.0 + i * 0.1
      }}
    }
  }.freeze

  LEAD_SIGNALS = {
    name: "lead_signals",
    desc: "Vendor lead signals — ~33/sec (2 k RPM), richer payload",
    gen: ->(i) {
      { store: :vendor_leads, key: "lead_#{SecureRandom.uuid}", value: {
        vendor_id:  "vendor_#{(i % 50) + 1}",
        zip_code:   "9#{(10_000 + i % 9_000)}",
        appliance:  %w[hvac fridge washer dryer][i % 4],
        signal:     %w[call_request form_submit chat_open][i % 3],
        score:      (i * 7 % 100).to_f,
        campaign:   "camp_#{i % 20}",
        channel:    %w[web mobile sms][i % 3],
        received_at: 1_746_182_400.0 + i * 0.03
      }}
    }
  }.freeze

  MIXED = {
    name: "mixed",
    desc: "70 % GPS + 20 % leads + 10 % CRM job records",
    gen: ->(i) {
      case i % 10
      when 0..6 then GPS_STREAM[:gen].call(i)
      when 7..8 then LEAD_SIGNALS[:gen].call(i)
      else
        { store: :crm_records, key: "job_#{i}", value: {
          job_id:    "job_#{i}",
          cust_id:   "cust_#{i % 10_000}",
          tech_id:   "tech_#{i % 200}",
          status:    %w[scheduled dispatched completed][i % 3],
          appliance: %w[hvac fridge washer][i % 3],
          zip_code:  "90#{i % 900}",
          notes:     "Service request"
        }}
      end
    }
  }.freeze

  ALL = [GPS_STREAM, LEAD_SIGNALS, MIXED].freeze
end

# ── Fact builder ──────────────────────────────────────────────────────────────

def build_fact(store:, key:, value:)
  ts = value[:recorded_at] || value[:received_at] || Process.clock_gettime(Process::CLOCK_REALTIME)
  {
    id:             SecureRandom.uuid,
    store:          store.to_s,
    key:            key.to_s,
    value:          value,
    value_hash:     Digest::SHA256.hexdigest(JSON.generate(stable_sort(value))),
    causation:      nil,
    timestamp:      ts,
    term:           0,
    schema_version: 1
  }
end

def stable_sort(v)
  case v
  when Hash  then v.sort_by { |k, _| k.to_s }.to_h { |k, x| [k.to_s, stable_sort(x)] }
  when Array then v.map { |x| stable_sort(x) }
  else            v
  end
end

def stringify(v)
  case v
  when Symbol then v.to_s
  when Hash   then v.transform_keys(&:to_s).transform_values { |x| stringify(x) }
  when Array  then v.map { |x| stringify(x) }
  else             v
  end
end

# ── WireProtocol helpers ──────────────────────────────────────────────────────

def encode_frame(body)
  b = body.b
  [b.bytesize].pack("N") + b + [Zlib.crc32(b)].pack("N")
end

def read_frame(io)
  h = io.read(4)
  return nil if h.nil? || h.bytesize < 4
  len  = h.unpack1("N")
  body = io.read(len)
  return nil if body.nil? || body.bytesize < len
  crc  = io.read(4)
  return nil if crc.nil? || crc.bytesize < 4
  return nil unless Zlib.crc32(body) == crc.unpack1("N")
  body
end

# ── Codecs ────────────────────────────────────────────────────────────────────
#
# Each entry:
#   name:      String            codec identifier
#   write_all: (facts, io) → Integer   total bytes written
#   read_all:  (io) → Integer          facts decoded (for throughput only)

BATCH_SIZE = 64

CODECS = []

# ── 1. json_crc32 ─────────────────────────────────────────────────────────────
# Current Ruby FileBackend behaviour. One JSON frame per fact, CRC32 integrity.
# This is the baseline for size and speed comparisons.

CODECS << {
  name: "json_crc32",
  write_all: ->(facts, io) {
    facts.sum { |f| io.write(encode_frame(JSON.generate(stringify(f)))) }
  },
  read_all: ->(io) {
    n = 0
    n += 1 while (b = read_frame(io)) && JSON.parse(b)
    n
  }
}

if MSGPACK_AVAILABLE
  # ── 2. msgpack_crc32 ───────────────────────────────────────────────────────
  # MessagePack, one frame per fact. Models the current native Rust FileBackend.
  # Binary type-tagged encoding eliminates JSON string overhead.

  CODECS << {
    name: "msgpack_crc32",
    write_all: ->(facts, io) {
      facts.sum { |f| io.write(encode_frame(MessagePack.pack(stringify(f)))) }
    },
    read_all: ->(io) {
      n = 0
      n += 1 while (b = read_frame(io)) && MessagePack.unpack(b)
      n
    }
  }

  # ── 3. msgpack_zlib_batch64 ────────────────────────────────────────────────
  # MessagePack facts batched 64-at-a-time, then Zlib-compressed. The larger
  # context window lets the compressor exploit repeated field names and key
  # strings across facts in the same batch. No structural changes to the Fact.

  CODECS << {
    name: "msgpack_zlib_batch64",
    write_all: ->(facts, io) {
      facts.each_slice(BATCH_SIZE).sum do |batch|
        raw  = MessagePack.pack(batch.map { |f| stringify(f) })
        body = [batch.size].pack("N") + Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
        io.write(encode_frame(body))
      end
    },
    read_all: ->(io) {
      n = 0
      while (body = read_frame(io))
        raw = Zlib::Inflate.inflate(body[4..])
        n  += MessagePack.unpack(raw).size
      end
      n
    }
  }

  # ── 4. compact_delta_zlib ──────────────────────────────────────────────────
  # Structural compression POC for History/sensor stores. Removes per-fact
  # overhead that is constant or derivable from the segment context:
  #
  #   id            → (segment_id, batch_idx) — not stored per entry
  #   store         → segment header (once per segment)
  #   value_hash    → not stored (content addressing done at batch level)
  #   causation     → always nil for sensor/history stores — omitted
  #   term          → in header
  #   schema_version→ in header
  #   value keys    → field index from segment dictionary
  #   key string    → key dictionary index (new keys delta-appended per batch)
  #   timestamp     → absolute ms for first entry; signed delta ms thereafter
  #
  # Segment layout:
  #   [dict_frame]  {store, fields:[...], term, schema_version}
  #   [batch_frame] {km:{idx=>key,...}, e:[[key_idx, delta_ms, [v0,v1,...]], ...]}
  #   [batch_frame] ...
  #
  # The key map (km) carries only NEW keys added in each batch so readers
  # accumulate it incrementally.

  CODECS << {
    name: "compact_delta_zlib",
    write_all: ->(facts, io) {
      return 0 if facts.empty?

      fields  = (facts.first[:value] || {}).keys.map(&:to_s).sort
      store   = facts.first[:store].to_s
      bytes   = 0

      # Segment dictionary frame
      dict = { store: store, fields: fields,
               term: facts.first[:term], schema_version: facts.first[:schema_version] }
      bytes += io.write(encode_frame(MessagePack.pack(stringify(dict))))

      key_map     = {}   # key_string → Integer index
      km_flushed  = 0    # how many keys were already sent to disk
      last_ts     = nil

      facts.each_slice(BATCH_SIZE) do |batch|
        entries = batch.map do |f|
          key = f[:key]
          key_map[key] ||= key_map.size

          ts    = f[:timestamp].to_f
          delta = last_ts ? ((ts - last_ts) * 1_000).round : (ts * 1_000).round
          last_ts = ts

          vals = fields.map { |fn|
            v = f[:value][fn.to_sym] || f[:value][fn]
            v.is_a?(Symbol) ? v.to_s : v
          }
          [key_map[key], delta, vals]
        end

        # Send only keys that are new since the last flush
        new_keys = key_map.select { |_, idx| idx >= km_flushed }
                         .invert
                         .transform_keys(&:to_s)
        km_flushed = key_map.size

        batch_body = { km: new_keys, e: entries }
        raw  = MessagePack.pack(stringify(batch_body))
        body = [batch.size].pack("N") + Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
        bytes += io.write(encode_frame(body))
      end

      bytes
    },
    read_all: ->(io) {
      return 0 unless read_frame(io)  # consume dict frame
      n       = 0
      key_map = {}  # idx_string → key

      while (body = read_frame(io))
        raw   = Zlib::Inflate.inflate(body[4..])
        batch = MessagePack.unpack(raw)
        (batch["km"] || {}).each { |idx, key| key_map[idx.to_s] = key }
        n += (batch["e"] || []).size
      end
      n
    }
  }
end

# ── Runner ────────────────────────────────────────────────────────────────────

def generate_facts(profile, count)
  count.times.map { |i| build_fact(**profile[:gen].call(i)) }
end

def benchmark_codec(codec, facts)
  dir  = Dir.mktmpdir("igniter_bench_")
  path = File.join(dir, "bench.wal")

  begin
    t0    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    bytes = File.open(path, "wb") { |io| codec[:write_all].call(facts, io) }
    t1    = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    n  = File.open(path, "rb") { |io| codec[:read_all].call(io) }
    t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    {
      codec:          codec[:name],
      facts:          facts.size,
      bytes:          bytes,
      bytes_per_fact: bytes.to_f / facts.size,
      write_fps:      facts.size / (t1 - t0),
      read_fps:       n / (t3 - t2),
      verified:       n == facts.size
    }
  rescue => e
    { codec: codec[:name], error: e.message }
  ensure
    FileUtils.rm_rf(dir)
  end
end

def run_profile(profile, fact_count)
  facts = generate_facts(profile, fact_count)
  CODECS.map { |codec| benchmark_codec(codec, facts) }
end

# ── Output ────────────────────────────────────────────────────────────────────

def print_table(profile, results, fact_count)
  valid    = results.reject { |r| r[:error] }
  baseline = valid.find { |r| r[:codec] == "json_crc32" }
  valid.each { |r| r[:ratio] = (baseline[:bytes_per_fact] / r[:bytes_per_fact]).round(2) } if baseline

  width = 80
  puts "\n#{"=" * width}"
  puts "Profile : #{profile[:name]}  —  #{profile[:desc]}"
  puts "Facts   : #{fact_count}"
  puts "=" * width
  fmt = "%-26s %11s %11s %11s %9s %7s"
  puts fmt % %w[Codec bytes/fact write_fps read_fps total_KB ratio]
  puts "-" * width

  results.each do |r|
    if r[:error]
      puts "%-26s  ERROR: %s" % [r[:codec], r[:error]]
    else
      puts fmt % [
        r[:codec],
        r[:bytes_per_fact].round(1),
        r[:write_fps].round(0),
        r[:read_fps].round(0),
        (r[:bytes] / 1024.0).round(1),
        r[:ratio] || "—"
      ]
    end
  end
  puts "=" * width

  # Daily volume projection at 10k sensors × 1 Hz
  puts "\nProjected daily volume — 10 k sensors × 1 Hz = 864 M facts/day:"
  valid.each do |r|
    gb = r[:bytes_per_fact] * 864_000_000 / 1_073_741_824.0
    puts "  %-26s %7.1f GB/day  (%.1fx baseline)" % [r[:codec], gb, r[:ratio]]
  end
end

# ── CLI ───────────────────────────────────────────────────────────────────────

cli = { profile: "all", facts: 5_000, json: false }
OptionParser.new do |o|
  o.banner = "Usage: ruby bench/storage_formats.rb [options]"
  o.on("--profile NAME", "gps_stream | lead_signals | mixed | all  (default: all)") { |v| cli[:profile] = v }
  o.on("--facts N",  Integer, "Facts per run (default: 5000)") { |v| cli[:facts] = v }
  o.on("--json",     "Print machine-readable JSON after tables") { cli[:json] = true }
end.parse!

profiles = cli[:profile] == "all" ? Profiles::ALL :
  [Profiles::ALL.find { |p| p[:name] == cli[:profile] } || Profiles::GPS_STREAM]

all_results = {}
profiles.each do |profile|
  results = run_profile(profile, cli[:facts])
  print_table(profile, results, cli[:facts])
  all_results[profile[:name]] = results
end

if cli[:json]
  puts "\n" + JSON.pretty_generate(
    all_results.transform_values { |rs|
      rs.map { |r| r.transform_values { |v| v.is_a?(Float) ? v.round(2) : v } }
    }
  )
end
