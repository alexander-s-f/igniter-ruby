# frozen_string_literal: true

require "json"
require "zlib"
require "digest"
require "securerandom"
require "msgpack"
require_relative "wire_protocol"

module Igniter
  module Store
    # Pluggable per-segment codec system for SegmentedFileBackend.
    #
    # Each codec owns the write side (how a Fact becomes bytes in a segment)
    # and the read side (how segment bytes become Facts on replay).
    #
    # Codec lifecycle per segment:
    #
    #   codec = Codecs.build(:compact_delta)
    #   codec.start_segment(io, store: "readings")   # optional header frame
    #   codec.encode_fact(io, fact)                  # returns bytes written
    #   ...
    #   codec.flush(io)                              # flush any buffered data
    #   ── seal ──
    #
    #   codec2 = Codecs.build(:compact_delta)
    #   facts  = codec2.decode(io)                   # reads whole segment
    #
    # Codec instances are stateful and single-use per segment.
    module Codecs
      # Build a fresh codec instance by name.
      def self.build(name)
        case name.to_sym
        when :json_crc32
          JsonCrc32.new
        when :compact_delta, :"compact_delta_zlib"
          CompactDelta.new
        else
          raise ArgumentError, "Unknown codec: #{name.inspect}"
        end
      end

      # ── JsonCrc32 ───────────────────────────────────────────────────────────
      #
      # One CRC32-framed JSON frame per fact. Matches the pure-Ruby FileBackend
      # format — readable without any extra dependencies.
      class JsonCrc32
        include WireProtocol

        NAME = "json_crc32"

        def name = NAME

        def start_segment(_io, store: nil) = 0   # no header needed

        def encode_fact(io, fact)
          frame = encode_frame(JSON.generate(fact.to_h))
          io.write(frame)
        end

        def flush(_io) = 0   # stateless, nothing buffered

        def buffered_count = 0

        def decode(io)
          facts = []
          loop do
            body = read_frame(io)
            break unless body
            fact = Fact.from_h(JSON.parse(body, symbolize_names: true)) rescue nil
            facts << fact if fact
          end
          facts
        end
      end

      # ── CompactDelta ────────────────────────────────────────────────────────
      #
      # Structural compression optimised for high-frequency History stores
      # (sensor readings, GPS tracks, telemetry).
      #
      # What is removed vs the full Fact representation:
      #   id            → not stored; synthetic id assigned on decode
      #   store         → in segment header (once per segment)
      #   value_hash    → not stored; recomputed from value on decode
      #   causation     → always nil for History — omitted
      #   term          → in segment header
      #   schema_version→ in segment header
      #   value keys    → field index from per-segment dictionary (header frame)
      #   key string    → per-segment key dictionary index (delta updates per batch)
      #   timestamp     → absolute ms for first entry; signed delta-ms thereafter
      #
      # Segment layout (all frames use WireProtocol CRC32 framing):
      #   [header_frame]  MessagePack { store, fields:[...], term, schema_version }
      #   [batch_frame]   MessagePack { km:{idx=>key,...}, e:[[ki,Δms,[v0,v1…]],…] }
      #                   compressed with Zlib before framing
      #   ...
      #
      # The key map (km) in each batch carries only NEW keys added since the
      # previous batch, so readers accumulate it incrementally.
      #
      # Benchmark result (GPS stream, 5 k facts):
      #   json_crc32   → 380 bytes/fact
      #   compact_delta→  23 bytes/fact   (16x smaller)
      #
      # Limitation (native mode): decoded Facts receive synthetic ids and, in
      # the Rust native extension, timestamps are reset to Time.now — the same
      # known gap as json_crc32 in native mode.  Pure-Ruby mode restores
      # timestamps correctly.
      class CompactDelta
        include WireProtocol

        NAME       = "compact_delta_zlib"
        BATCH_SIZE = 64

        def name = NAME

        # ── Write side ──────────────────────────────────────────────────────

        def initialize
          @fields          = nil
          @key_map         = {}   # key_string → Integer index
          @km_flushed      = 0    # keys already sent to disk
          @last_ts_ms      = nil
          @batch_buf       = []
          @header_written  = false
          @store           = nil
        end

        def start_segment(_io, store: nil)
          @store = store.to_s
          0  # header is written lazily on first encode_fact call
        end

        # Returns bytes written to io (0 while batch is buffered).
        def encode_fact(io, fact)
          unless @header_written
            @fields = (fact.value || {}).keys.map(&:to_s).sort
            header  = { store: fact.store.to_s, fields: @fields,
                        valid_time: fact.valid_time, schema_version: fact.schema_version }
            body = MessagePack.pack(stringify(header))
            io.write(encode_frame(body))
            @header_written = true
          end

          @batch_buf << fact
          @batch_buf.size >= BATCH_SIZE ? write_batch(io) : 0
        end

        # Flush any remaining buffered facts. Returns bytes written.
        def flush(io)
          @batch_buf.empty? ? 0 : write_batch(io)
        end

        def buffered_count = @batch_buf.size

        # ── Read side ────────────────────────────────────────────────────────

        def decode(io)
          header_body = read_frame(io)
          return [] unless header_body
          header = MessagePack.unpack(header_body)
          fields = header["fields"] || []
          store      = (header["store"] || "").to_sym
          valid_time = (header["valid_time"] || header["term"])&.to_f
          sv         = (header["schema_version"] || 1).to_i

          key_map    = {}    # Integer index → key_string
          last_ts_ms = nil
          facts      = []

          while (body = read_frame(io))
            _count = body[0, 4].unpack1("N")
            raw    = Zlib::Inflate.inflate(body[4..])
            batch  = MessagePack.unpack(raw)

            (batch["km"] || {}).each { |idx, key| key_map[idx.to_i] = key }

            (batch["e"] || []).each do |key_idx, delta_ms, vals|
              ts_ms      = last_ts_ms ? last_ts_ms + delta_ms : delta_ms
              last_ts_ms = ts_ms

              value = fields.each_with_index.to_h { |fn, i| [fn.to_sym, vals[i]] }
              vh    = Digest::SHA256.hexdigest(JSON.generate(stable_sort(value)))

              fact_hash = {
                id:               SecureRandom.uuid,
                store:            store,
                key:              key_map[key_idx.to_i],
                value:            value,
                value_hash:       vh,
                causation:        nil,
                transaction_time: ts_ms / 1_000.0,
                valid_time:       valid_time,
                schema_version:   sv
              }
              fact = Fact.from_h(fact_hash) rescue nil
              facts << fact if fact
            end
          end

          facts
        end

        private

        def write_batch(io)
          entries = @batch_buf.map do |f|
            key = f.key.to_s
            @key_map[key] ||= @key_map.size

            ts_ms   = (f.transaction_time.to_f * 1_000).round
            delta   = @last_ts_ms ? ts_ms - @last_ts_ms : ts_ms
            @last_ts_ms = ts_ms

            vals = @fields.map { |fn|
              v = f.value.key?(fn.to_sym) ? f.value[fn.to_sym] : f.value[fn]
              v.is_a?(Symbol) ? v.to_s : v
            }
            [@key_map[key], delta, vals]
          end

          new_keys = @key_map.select { |_, idx| idx >= @km_flushed }
                             .invert
                             .transform_keys(&:to_s)
          @km_flushed = @key_map.size

          raw  = MessagePack.pack(stringify({ km: new_keys, e: entries }))
          body = [@batch_buf.size].pack("N") + Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)
          @batch_buf.clear
          io.write(encode_frame(body))
        end

        def stringify(v)
          case v
          when Symbol then v.to_s
          when Hash   then v.transform_keys(&:to_s).transform_values { |x| stringify(x) }
          when Array  then v.map { |x| stringify(x) }
          else             v
          end
        end

        def stable_sort(v)
          case v
          when Hash  then v.sort_by { |k, _| k.to_s }.to_h { |k, x| [k.to_s, stable_sort(x)] }
          when Array then v.map { |x| stable_sort(x) }
          else            v
          end
        end
      end
    end
  end
end
