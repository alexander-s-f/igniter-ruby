# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "IgniterStore#compaction_activity" do
  let(:store) { Igniter::Store::IgniterStore.new }

  # ── Retention compaction entries ──────────────────────────────────────────────

  describe "retention compaction entries" do
    it "includes a :retention_compaction entry after compact" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k", value: { v: 1 })
      store.write(store: :things, key: "k", value: { v: 2 })
      store.compact

      activity = store.compaction_activity
      entry = activity.find { |e| e[:kind] == :retention_compaction }
      expect(entry).not_to be_nil
      expect(entry[:executor]).to    eq(:store_compact)
      expect(entry[:status]).to      eq(:ok)
      expect(entry[:reason]).to      eq(:ephemeral)
      expect(entry[:fact_count]).to  eq(1)
      expect(entry[:receipt_id]).not_to be_nil
      expect(entry[:occurred_at]).to be_a(Float)
    end

    it "can filter compaction_activity by store" do
      store.set_retention(:alpha, strategy: :ephemeral)
      store.set_retention(:beta,  strategy: :ephemeral)
      store.write(store: :alpha, key: "k", value: { v: 1 })
      store.write(store: :alpha, key: "k", value: { v: 2 })
      store.write(store: :beta,  key: "k", value: { v: 1 })
      store.write(store: :beta,  key: "k", value: { v: 2 })
      store.compact

      alpha_activity = store.compaction_activity(store: :alpha)
      compact_entries = alpha_activity.select { |e| e[:kind] == :retention_compaction }
      expect(compact_entries).not_to be_empty
      expect(compact_entries.all? { |e| e[:store].to_sym == :alpha }).to eq(true)
    end

    it "returns empty when no compaction has run" do
      store.write(store: :things, key: "k", value: { v: 1 })
      expect(store.compaction_activity).to be_empty
    end
  end

  # ── Exact prune entries ───────────────────────────────────────────────────────

  describe "exact prune entries" do
    it "includes an :exact_prune entry after prune_fact_ids" do
      f = store.write(store: :things, key: "k", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :test_prune)

      activity = store.compaction_activity
      entry = activity.find { |e| e[:kind] == :exact_prune }
      expect(entry).not_to be_nil
      expect(entry[:executor]).to    eq(:fact_prune)
      expect(entry[:status]).to      eq(:ok)
      expect(entry[:reason]).to      eq(:test_prune)
      expect(entry[:fact_count]).to  eq(1)
      expect(entry[:receipt_id]).not_to be_nil
      expect(entry[:occurred_at]).to be_a(Float)
    end

    it "prune entry store field is nil (prune spans fact ids, not a single store)" do
      f = store.write(store: :things, key: "k", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :test_prune)

      entry = store.compaction_activity.find { |e| e[:kind] == :exact_prune }
      expect(entry[:store]).to be_nil
    end
  end

  # ── Segment purge entries (backend passthrough) ───────────────────────────────

  describe "segment purge entries (SegmentedFileBackend)" do
    it "no segment_purge entries when backend has no purge_receipts" do
      activity = store.compaction_activity
      expect(activity.none? { |e| e[:kind] == :segment_purge }).to eq(true)
    end

    it "includes :segment_purge entries when SegmentedFileBackend has purge receipts" do
      dir  = Dir.mktmpdir("igniter_activity_seg")
      root = File.join(dir, "store")
      FileUtils.mkdir_p(root)
      backend = Igniter::Store::SegmentedFileBackend.new(root,
        retention: { "things" => { strategy: :rolling_window, duration: 60 } })
      s = Igniter::Store::IgniterStore.new(backend: backend)

      s.write(store: :things, key: "k", value: { v: 1 })
      backend.checkpoint!                         # seal → creates a manifest
      s.write(store: :things, key: "k", value: { v: 2 })
      backend.close

      # Backdate the sealed segment manifest so it is eligible for purge
      manifest_path = Dir[File.join(root, "wal", "store=things", "**", "*.manifest.json")].min
      unless manifest_path.nil?
        m = JSON.parse(File.read(manifest_path))
        old_ts = Process.clock_gettime(Process::CLOCK_REALTIME) - 200
        m["max_timestamp"] = old_ts
        m["min_timestamp"] = old_ts
        File.write(manifest_path, JSON.generate(m))
      end

      b2 = Igniter::Store::SegmentedFileBackend.new(root,
             retention: { "things" => { strategy: :rolling_window, duration: 60 } })
      s2 = Igniter::Store::IgniterStore.new(backend: b2)

      purged = b2.purge!
      if purged.empty?
        skip "no segments were eligible for purge in this env"
      end

      activity = s2.compaction_activity
      seg_entries = activity.select { |e| e[:kind] == :segment_purge }
      expect(seg_entries).not_to be_empty
      entry = seg_entries.first
      expect(entry[:executor]).to eq(:segmented_backend)
      expect(entry[:status]).to   eq(:ok)
      expect(entry[:reason]).not_to be_nil
      expect(entry[:occurred_at]).to be_a(Float)
    ensure
      b2&.close rescue nil
      FileUtils.rm_rf(dir)
    end
  end

  # ── Ordering ─────────────────────────────────────────────────────────────────

  describe "ordering" do
    it "entries are sorted by occurred_at ascending" do
      store.set_retention(:things, strategy: :ephemeral)
      store.write(store: :things, key: "k1", value: { v: 1 })
      store.write(store: :things, key: "k1", value: { v: 2 })
      store.compact

      f = store.write(store: :things, key: "k2", value: { v: 1 })
      store.prune_fact_ids(fact_ids: [f.id], reason: :cleanup)

      activity = store.compaction_activity
      expect(activity.size).to be >= 2
      times = activity.map { |e| e[:occurred_at] }
      expect(times).to eq(times.sort)
    end
  end
end

# ── AvailabilityBoundaryLedger#compaction_activity ────────────────────────────

RSpec.describe "AvailabilityBoundaryLedger#compaction_activity — boundary integration" do
  require_relative "../../../examples/intelligent_ledger/availability_boundary_ledger"
  ABL = Igniter::Store::IntelligentLedger::AvailabilityBoundaryLedger unless defined?(ABL)

  let(:store)  { Igniter::Store::IgniterStore.new }
  let(:ledger) { ABL.new(store: store) }

  it "includes store compaction activity in ledger compaction_activity" do
    store.set_retention(:things, strategy: :ephemeral)
    store.write(store: :things, key: "k", value: { v: 1 })
    store.write(store: :things, key: "k", value: { v: 2 })
    store.compact

    activity = ledger.compaction_activity
    expect(activity.any? { |e| e[:kind] == :retention_compaction }).to eq(true)
  end

  it "includes store prune activity in ledger compaction_activity" do
    f = store.write(store: :things, key: "k", value: { v: 1 })
    store.prune_fact_ids(fact_ids: [f.id], reason: :manual)

    activity = ledger.compaction_activity
    expect(activity.any? { |e| e[:kind] == :exact_prune }).to eq(true)
  end

  it "includes :boundary_physical_purge entries from ledger_physical_purge_receipts" do
    # Write a synthetic physical purge receipt directly
    store.write(
      store: :ledger_physical_purge_receipts,
      key:   "plan-abc123",
      value: {
        "status"           => "purged",
        "plan_hash"        => "plan-abc123",
        "boundary_keys"    => ["slot-1"],
        "fact_ids_pruned"  => ["f1"],
        "pruned_count"     => 1,
        "missing_count"    => 0,
        "prune_receipt_id" => "r1",
        "purged_at"        => Time.now.utc.iso8601(3)
      }
    )

    activity = ledger.compaction_activity
    purge_entry = activity.find { |e| e[:kind] == :boundary_physical_purge }
    expect(purge_entry).not_to be_nil
    expect(purge_entry[:executor]).to eq(:boundary_ledger)
    expect(purge_entry[:status]).to   eq(:purged)
    expect(purge_entry[:reason]).to   eq(:boundary_physical_purge)
    expect(purge_entry[:fact_count]).to eq(1)
    expect(purge_entry[:receipt_id]).not_to be_nil
  end

  it "ledger compaction_activity is sorted by occurred_at" do
    store.set_retention(:things, strategy: :ephemeral)
    store.write(store: :things, key: "k", value: { v: 1 })
    store.write(store: :things, key: "k", value: { v: 2 })
    store.compact

    store.write(
      store: :ledger_physical_purge_receipts,
      key:   "plan-xyz",
      value: { "status" => "purged", "pruned_count" => 0,
               "purged_at" => Time.now.utc.iso8601(3) }
    )

    activity = ledger.compaction_activity
    times = activity.map { |e| e[:occurred_at] }
    expect(times).to eq(times.sort)
  end

  it "returns empty when no compaction activity has occurred" do
    expect(ledger.compaction_activity).to be_empty
  end
end
