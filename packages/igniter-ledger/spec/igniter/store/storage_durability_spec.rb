# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"
require "fileutils"

# Storage Durability Contract Spec
#
# Proves the durability guarantees for each codec and flush policy combination.
# "Crash" is simulated by closing raw IO handles without going through seal/close,
# then reopening a fresh backend (which runs recover_orphaned_segments! on init).
#
# Durability matrix:
#
#   Codec          Policy       Sub-batch crash   Full-batch crash
#   json_crc32     any          0 facts lost       0 facts lost
#   compact_delta  :batch       all buffered lost  0 facts lost (batch was on disk)
#   compact_delta  :on_write    0 facts lost       0 facts lost
#   compact_delta  every_n: N   (count % N) lost   (count % N) lost
#
RSpec.describe "Storage durability contract" do
  BATCH_SIZE = Igniter::Store::Codecs::CompactDelta::BATCH_SIZE

  def make_fact(key: "k1", value: { x: 1 }, store: :readings)
    Igniter::Store::Fact.build(store: store, key: key, value: value)
  end

  def n_facts(n, store: :readings)
    n.times.map { |i| make_fact(key: "k#{i}", value: { v: i }, store: store) }
  end

  # Simulate a process crash: close raw IO without sealing or writing manifests.
  def simulate_crash(backend)
    backend.instance_variable_get(:@segments).each_value do |seg|
      seg[:file].close rescue nil
    end
    backend.instance_variable_get(:@segments).clear
  end

  # Write facts, crash, reopen, replay. Returns recovered facts.
  def crash_and_reopen(tmpdir, facts, codec:, flush: :batch)
    backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: codec, flush: flush)
    facts.each { |f| backend.write_fact(f) }
    simulate_crash(backend)

    backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: codec)
    recovered = backend2.replay
    backend2.close
    recovered
  end

  # ── json_crc32 ───────────────────────────────────────────────────────────────

  describe "json_crc32: per-fact sync writes, nothing buffered" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-json-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "all facts survive a crash (sync=true, every fact is a framed write)" do
      facts = n_facts(10)
      recovered = crash_and_reopen(tmpdir, facts, codec: :json_crc32)
      expect(recovered.size).to eq(10)
    end

    it "single fact survives crash" do
      recovered = crash_and_reopen(tmpdir, [make_fact(key: "only")], codec: :json_crc32)
      expect(recovered.size).to eq(1)
      expect(recovered.first.key).to eq("only")
    end

    it "durability_snapshot always shows buffered_count: 0" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :json_crc32)
      3.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      snap = backend.durability_snapshot
      expect(snap["policy"]).to eq("batch")
      expect(snap["stores"]["readings"]["buffered_count"]).to eq(0)
      expect(snap["stores"]["readings"]["durability"]).to eq("flushed")
      backend.close
    end
  end

  # ── compact_delta :batch (default) ───────────────────────────────────────────

  describe "compact_delta :batch policy (default)" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-cd-batch-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "sub-batch facts are LOST on crash (less than BATCH_SIZE written)" do
      facts = n_facts(3)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta)
      expect(recovered.size).to eq(0)
    end

    it "exactly one full batch survives crash (BATCH_SIZE facts on disk)" do
      facts = n_facts(BATCH_SIZE)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta)
      expect(recovered.size).to eq(BATCH_SIZE)
    end

    it "facts beyond the last full batch boundary are lost on crash" do
      remainder = 6
      total     = BATCH_SIZE + remainder
      facts     = n_facts(total)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta)
      expect(recovered.size).to eq(BATCH_SIZE)
    end

    it "two full batches survive crash" do
      facts = n_facts(BATCH_SIZE * 2)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta)
      expect(recovered.size).to eq(BATCH_SIZE * 2)
    end

    it "durability_snapshot shows buffered_count for unflushed facts" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      5.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      snap = backend.durability_snapshot
      expect(snap["policy"]).to eq("batch")
      store_snap = snap["stores"]["readings"]
      expect(store_snap["buffered_count"]).to eq(5)
      expect(store_snap["facts_on_disk"]).to eq(0)
      expect(store_snap["durability"]).to eq("buffered")
      backend.close
    end

    it "durability_snapshot shows flushed after checkpoint!" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      5.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      backend.checkpoint!
      snap = backend.durability_snapshot
      store_snap = snap["stores"]["readings"]
      expect(store_snap["buffered_count"]).to eq(0)
      expect(store_snap["durability"]).to eq("flushed")
      backend.close
    end

    it "no quarantine receipt for empty crash-recovered segment" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      3.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      simulate_crash(backend)

      backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      expect(backend2.quarantine_receipts).to be_empty
      backend2.close
    end
  end

  # ── compact_delta :on_write ───────────────────────────────────────────────────

  describe "compact_delta :on_write flush policy" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-cd-ow-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "all facts survive a crash (flushed after every write)" do
      facts = n_facts(10)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta, flush: :on_write)
      expect(recovered.size).to eq(10)
    end

    it "single fact survives crash" do
      recovered = crash_and_reopen(tmpdir, [make_fact(key: "single")],
                                   codec: :compact_delta, flush: :on_write)
      expect(recovered.size).to eq(1)
    end

    it "durability_snapshot shows batch: buffered, on_write: flushed" do
      backend_batch = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta, flush: :batch)
      backend_ow    = Igniter::Store::SegmentedFileBackend.new(Dir.mktmpdir("dur-ow-snap-"), codec: :compact_delta, flush: :on_write)

      3.times { |i| backend_batch.write_fact(make_fact(key: "k#{i}")) }
      3.times { |i| backend_ow.write_fact(make_fact(key: "k#{i}")) }

      snap_batch = backend_batch.durability_snapshot
      snap_ow    = backend_ow.durability_snapshot

      expect(snap_batch["stores"]["readings"]["durability"]).to eq("buffered")
      expect(snap_ow["stores"]["readings"]["durability"]).to   eq("flushed")

      backend_batch.close
      backend_ow.close
    end

    it "durability_snapshot policy name is on_write" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta, flush: :on_write)
      backend.write_fact(make_fact)
      expect(backend.durability_snapshot["policy"]).to eq("on_write")
      backend.close
    end
  end

  # ── compact_delta every_n ────────────────────────────────────────────────────

  describe "compact_delta every_n: N flush policy" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-cd-en-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "survives only facts rounded down to flush boundary" do
      # every_n: 5 — flushes at 5, 10 → 10 survive; 3 remaining lost
      facts = n_facts(13)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta, flush: { every_n: 5 })
      expect(recovered.size).to eq(10)
    end

    it "exactly N facts survive after one flush cycle, crash before second" do
      facts = n_facts(7)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta, flush: { every_n: 5 })
      expect(recovered.size).to eq(5)
    end

    it "0 facts survive if crash before first flush boundary" do
      facts = n_facts(4)
      recovered = crash_and_reopen(tmpdir, facts, codec: :compact_delta, flush: { every_n: 5 })
      expect(recovered.size).to eq(0)
    end

    it "durability_snapshot policy name encodes every_n value" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta, flush: { every_n: 10 })
      backend.write_fact(make_fact)
      expect(backend.durability_snapshot["policy"]).to eq("every_n:10")
      backend.close
    end

    it "durability_snapshot reflects remaining buffered count between flushes" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta, flush: { every_n: 5 })
      7.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      snap = backend.durability_snapshot
      store_snap = snap["stores"]["readings"]
      expect(store_snap["facts_on_disk"]).to  eq(5)
      expect(store_snap["buffered_count"]).to eq(2)
      expect(store_snap["durability"]).to     eq("buffered")
      backend.close
    end
  end

  # ── checkpoint! and close durability ─────────────────────────────────────────

  describe "checkpoint! and close flush all buffers" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-seal-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "checkpoint! persists sub-batch compact_delta facts" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      5.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      backend.checkpoint!
      backend.close

      backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      expect(backend2.replay.size).to eq(5)
      backend2.close
    end

    it "close persists sub-batch compact_delta facts" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      5.times { |i| backend.write_fact(make_fact(key: "k#{i}")) }
      backend.close

      backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      expect(backend2.replay.size).to eq(5)
      backend2.close
    end
  end

  # ── multi-store crash recovery ───────────────────────────────────────────────

  describe "crash recovery with multiple stores" do
    let(:tmpdir) { Dir.mktmpdir("dur-spec-multi-") }
    after { FileUtils.rm_rf(tmpdir) }

    it "json_crc32: all stores recover after crash" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :json_crc32)
      3.times { |i| backend.write_fact(make_fact(store: :alpha, key: "k#{i}")) }
      4.times { |i| backend.write_fact(make_fact(store: :beta,  key: "k#{i}")) }
      simulate_crash(backend)

      backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :json_crc32)
      expect(backend2.replay(store: :alpha).size).to eq(3)
      expect(backend2.replay(store: :beta).size).to  eq(4)
      backend2.close
    end

    it "compact_delta :on_write: all stores recover after crash" do
      backend = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta, flush: :on_write)
      3.times { |i| backend.write_fact(make_fact(store: :alpha, key: "k#{i}")) }
      4.times { |i| backend.write_fact(make_fact(store: :beta,  key: "k#{i}")) }
      simulate_crash(backend)

      backend2 = Igniter::Store::SegmentedFileBackend.new(tmpdir, codec: :compact_delta)
      expect(backend2.replay(store: :alpha).size).to eq(3)
      expect(backend2.replay(store: :beta).size).to  eq(4)
      backend2.close
    end
  end
end
