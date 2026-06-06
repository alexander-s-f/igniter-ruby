# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "IgniterStore#compact — durability barrier" do
  # ── Resurrection bug (write_snapshot does not prevent WAL replay) ─────────────
  # Documents the historical gap: non-destructive write_snapshot leaves the WAL
  # intact, so compacted facts can replay back on reopen.  This spec proves the
  # gap exists when the prune barrier is bypassed.

  describe "resurrection bug (write_snapshot leaves WAL intact)" do
    it "a compacted fact is resurrected from WAL when only write_snapshot is called" do
      dir  = Dir.mktmpdir("igniter_compact_res")
      path = File.join(dir, "test.wal")

      s1 = Igniter::Store.open(path)
      s1.write(store: :things, key: "k", value: { v: 1 })
      s1.write(store: :things, key: "k", value: { v: 2 })

      # Simulate the old compact_store behavior: rebuild in-memory, then call only
      # write_snapshot (non-destructive — WAL left intact with both facts).
      kept = s1.instance_variable_get(:@log).all_facts
               .group_by { |f| [f.store, f.key] }
               .transform_values { |fs| [fs.max_by(&:transaction_time)] }
               .values.flatten
      s1.send(:rebuild_log!, kept)

      backend = s1.instance_variable_get(:@backend)
      backend.write_snapshot(s1.instance_variable_get(:@log).all_facts)
      backend.close

      # Reopen: WAL still contains both facts → old fact resurrected
      s2 = Igniter::Store.open(path)
      history = s2.history(store: :things, key: "k")
      expect(history.size).to be > 1,
        "expected old fact to be resurrected from WAL — documents the historical gap"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # ── replace_with_snapshot! prevents resurrection ──────────────────────────────

  describe "compact with replace_with_snapshot! barrier" do
    let(:dir)  { Dir.mktmpdir("igniter_compact_dur") }
    let(:path) { File.join(dir, "test.wal") }

    after { FileUtils.rm_rf(dir) }

    it "compacted facts do not return after close/reopen" do
      s1 = Igniter::Store.open(path)
      s1.set_retention(:things, strategy: :ephemeral)
      s1.write(store: :things, key: "k", value: { v: 1 })
      s1.write(store: :things, key: "k", value: { v: 2 })

      result = s1.compact
      expect(result.first[:durable]).to eq(true)

      s1.instance_variable_get(:@backend).close

      s2 = Igniter::Store.open(path)
      expect(s2.history(store: :things, key: "k").size).to eq(1)
      expect(s2.read(store: :things, key: "k")).to include(v: 2)
    end

    it "fact written after compact survives reopen" do
      s1 = Igniter::Store.open(path)
      s1.set_retention(:things, strategy: :ephemeral)
      s1.write(store: :things, key: "k", value: { v: 1 })
      s1.write(store: :things, key: "k", value: { v: 2 })
      s1.compact

      s1.write(store: :things, key: "new", value: { v: 99 })
      s1.instance_variable_get(:@backend).close

      s2 = Igniter::Store.open(path)
      expect(s2.read(store: :things, key: "new")).to include(v: 99)
    end

    it "returns durable: true when FileBackend supports replace_with_snapshot!" do
      s1 = Igniter::Store.open(path)
      s1.set_retention(:things, strategy: :ephemeral)
      s1.write(store: :things, key: "k", value: { v: 1 })
      s1.write(store: :things, key: "k", value: { v: 2 })

      results = s1.compact
      expect(results.first[:durable]).to eq(true)
    end

    it "compact receipt survives the barrier and is queryable after reopen" do
      s1 = Igniter::Store.open(path)
      s1.set_retention(:things, strategy: :ephemeral)
      s1.write(store: :things, key: "k", value: { v: 1 })
      s1.write(store: :things, key: "k", value: { v: 2 })
      s1.compact

      s1.instance_variable_get(:@backend).close

      s2 = Igniter::Store.open(path)
      receipts = s2.compaction_receipts
      expect(receipts).not_to be_empty
      # Use .to_sym for resilience: in native mode the store name is a String after
      # snapshot round-trip (Ruby JSON converts Symbol values to bare strings).
      expect(receipts.last.value[:compacted_store].to_sym).to eq(:things)
    end
  end

  # ── In-memory store (no backend) ─────────────────────────────────────────────

  describe "in-memory store (no backend)" do
    it "compact still works without a backend" do
      s = Igniter::Store::IgniterStore.new
      s.set_retention(:things, strategy: :ephemeral)
      s.write(store: :things, key: "k", value: { v: 1 })
      s.write(store: :things, key: "k", value: { v: 2 })

      results = s.compact
      expect(results.first[:dropped_count]).to eq(1)
      expect(results.first[:durable]).to eq(false)
      expect(s.history(store: :things, key: "k").size).to eq(1)
    end

    it "returns durable: false when no backend is present" do
      s = Igniter::Store::IgniterStore.new
      s.set_retention(:things, strategy: :ephemeral)
      s.write(store: :things, key: "k", value: { v: 1 })
      s.write(store: :things, key: "k", value: { v: 2 })

      results = s.compact
      expect(results.first[:durable]).to eq(false)
    end
  end

  # ── SegmentedFileBackend (no replace_with_snapshot!) ─────────────────────────

  describe "SegmentedFileBackend (no replace_with_snapshot!)" do
    it "SegmentedFileBackend does not respond to replace_with_snapshot!" do
      dir     = Dir.mktmpdir("igniter_seg_nosnap")
      backend = Igniter::Store::SegmentedFileBackend.new(dir)
      expect(backend).not_to respond_to(:replace_with_snapshot!)
    ensure
      backend&.close
      FileUtils.rm_rf(dir)
    end

    it "compact returns durable: false with SegmentedFileBackend" do
      dir     = Dir.mktmpdir("igniter_seg_compact")
      backend = Igniter::Store::SegmentedFileBackend.new(dir)
      s       = Igniter::Store::IgniterStore.new(backend: backend)

      s.set_retention(:things, strategy: :ephemeral)
      s.write(store: :things, key: "k", value: { v: 1 })
      s.write(store: :things, key: "k", value: { v: 2 })

      results = s.compact
      expect(results.first[:durable]).to     eq(false)
      expect(results.first[:dropped_count]).to eq(1)
    ensure
      backend&.close
      FileUtils.rm_rf(dir)
    end
  end

  # ── Return shape ──────────────────────────────────────────────────────────────

  describe "return shape" do
    it "returns durable: false when nothing was dropped" do
      dir  = Dir.mktmpdir("igniter_nodrop")
      path = File.join(dir, "test.wal")
      s    = Igniter::Store.open(path)
      s.set_retention(:things, strategy: :ephemeral)
      s.write(store: :things, key: "k", value: { v: 1 })

      results = s.compact
      expect(results.first[:dropped_count]).to eq(0)
      expect(results.first[:durable]).to       eq(false)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
