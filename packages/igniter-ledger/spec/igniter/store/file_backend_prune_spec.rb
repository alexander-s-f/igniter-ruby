# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "FileBackend — pruning barrier (replace_with_snapshot!)" do
  let(:dir)  { Dir.mktmpdir("igniter_prune_spec") }
  let(:path) { File.join(dir, "test.wal") }

  after { FileUtils.rm_rf(dir) }

  # ── Resurrection bug spec ──────────────────────────────────────────────────
  # Proves the known gap: write_snapshot (normal checkpoint) leaves the WAL
  # intact, so facts absent from the snapshot are replayed back on reopen.

  describe "resurrection bug (normal checkpoint does not prevent replay)" do
    it "a fact not in the snapshot is resurrected from the WAL on reopen" do
      s1 = Igniter::Store.open(path)
      s1.write(store: :items, key: "keep", value: { v: 1 })
      s1.write(store: :items, key: "drop", value: { v: 2 })

      drop_id = s1.fact_by_id(s1.history(store: :items, key: "drop").last.id)&.id

      # Normal checkpoint: snapshot has both facts, WAL unchanged
      s1.checkpoint

      # Simulate "drop" by rebuilding with only "keep"
      kept = s1.instance_variable_get(:@log).all_facts
               .reject { |f| f.store == :items && f.key == "drop" }
      s1.send(:rebuild_log!, kept)

      # write_snapshot: snapshot now has only "keep"; WAL still has "drop"
      s1.instance_variable_get(:@backend).write_snapshot(
        s1.instance_variable_get(:@log).all_facts
      )
      s1.instance_variable_get(:@backend).close

      # Reopen: WAL replays "drop" back (resurrection bug)
      s2 = Igniter::Store.open(path)
      resurrected = s2.history(store: :items, key: "drop")
      expect(resurrected).not_to be_empty,
        "expected 'drop' to be resurrected from WAL — this documents the known bug"
    end
  end

  # ── replace_with_snapshot! prevents resurrection ───────────────────────────

  describe "replace_with_snapshot! prevents resurrection" do
    it "a fact pruned via replace_with_snapshot! does not return after reopen" do
      s1 = Igniter::Store.open(path)
      s1.write(store: :items, key: "keep", value: { v: 1 })
      s1.write(store: :items, key: "drop", value: { v: 2 })

      # Simulate prune: rebuild without "drop"
      kept = s1.instance_variable_get(:@log).all_facts
               .reject { |f| f.store == :items && f.key == "drop" }
      s1.send(:rebuild_log!, kept)

      # replace_with_snapshot!: snapshot written AND WAL truncated
      backend = s1.instance_variable_get(:@backend)
      backend.replace_with_snapshot!(s1.instance_variable_get(:@log).all_facts)
      backend.close

      # Reopen: only snapshot facts are loaded; "drop" does NOT return
      s2 = Igniter::Store.open(path)
      expect(s2.history(store: :items, key: "drop")).to be_empty
      expect(s2.history(store: :items, key: "keep")).not_to be_empty
    end

    it "facts written after replace_with_snapshot! survive the next reopen" do
      s1 = Igniter::Store.open(path)
      s1.write(store: :items, key: "old", value: { v: 1 })

      kept = s1.instance_variable_get(:@log).all_facts
               .reject { |f| f.store == :items && f.key == "old" }
      s1.send(:rebuild_log!, kept)

      backend = s1.instance_variable_get(:@backend)
      backend.replace_with_snapshot!(s1.instance_variable_get(:@log).all_facts)

      # Write new fact AFTER the barrier
      s1.write(store: :items, key: "new", value: { v: 2 })
      backend.close

      s2 = Igniter::Store.open(path)
      expect(s2.history(store: :items, key: "new")).not_to be_empty
      expect(s2.history(store: :items, key: "old")).to be_empty
    end

    it "calling replace_with_snapshot! twice is safe (idempotent barrier)" do
      s1 = Igniter::Store.open(path)
      s1.write(store: :items, key: "k1", value: { v: 1 })

      backend   = s1.instance_variable_get(:@backend)
      survivors = s1.instance_variable_get(:@log).all_facts

      expect { backend.replace_with_snapshot!(survivors) }.not_to raise_error
      expect { backend.replace_with_snapshot!(survivors) }.not_to raise_error

      backend.close
      s2 = Igniter::Store.open(path)
      expect(s2.history(store: :items, key: "k1")).not_to be_empty
    end
  end

  # ── IgniterStore.prune_fact_ids uses the barrier ────────────────────────────

  describe "IgniterStore#prune_fact_ids integrates the barrier" do
    it "pruned fact is absent from live index immediately after prune" do
      s = Igniter::Store.open(path)
      s.write(store: :items, key: "a", value: { v: 1 })
      fact_id = s.history(store: :items, key: "a").last.id

      s.prune_fact_ids(fact_ids: [fact_id], reason: :test_prune)

      expect(s.fact_by_id(fact_id)).to be_nil
    end

    it "pruned fact does not return after close/reopen" do
      s1 = Igniter::Store.open(path)
      s1.write(store: :items, key: "b", value: { v: 1 })
      fact_id = s1.history(store: :items, key: "b").last.id

      s1.prune_fact_ids(fact_ids: [fact_id], reason: :test_prune)
      s1.instance_variable_get(:@backend).close

      s2 = Igniter::Store.open(path)
      expect(s2.fact_by_id(fact_id)).to be_nil
      expect(s2.history(store: :items, key: "b")).to be_empty
    end
  end
end
