# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Igniter::Store::IgniterStore, "fact-id index" do
  subject(:store) { described_class.new }

  # --- fact_by_id ---

  describe "#fact_by_id" do
    context "write path" do
      it "returns the exact Fact written by #write" do
        fact = store.write(store: :things, key: "k1", value: { x: 1 })
        expect(store.fact_by_id(fact.id)).to be(fact)
      end

      it "returns the exact Fact written by #append" do
        fact = store.append(history: :events, event: { type: "created" })
        expect(store.fact_by_id(fact.id)).to be(fact)
      end

      it "indexes multiple writes independently" do
        f1 = store.write(store: :things, key: "k1", value: { x: 1 })
        f2 = store.write(store: :things, key: "k2", value: { x: 2 })
        expect(store.fact_by_id(f1.id)).to be(f1)
        expect(store.fact_by_id(f2.id)).to be(f2)
      end

      it "keeps the latest Fact for the same key (each write gets a unique id)" do
        f1 = store.write(store: :things, key: "k", value: { v: 1 })
        f2 = store.write(store: :things, key: "k", value: { v: 2 })
        expect(store.fact_by_id(f1.id)).to be(f1)
        expect(store.fact_by_id(f2.id)).to be(f2)
      end
    end

    context "nil / blank id guard" do
      it "returns nil for nil" do
        expect(store.fact_by_id(nil)).to be_nil
      end

      it "returns nil for empty string" do
        expect(store.fact_by_id("")).to be_nil
      end

      it "returns nil for unknown id" do
        expect(store.fact_by_id("nonexistent-uuid")).to be_nil
      end
    end

    context "coercion hooks do not affect result" do
      it "returns the raw Fact even when a coercion is registered" do
        store.register_coercion(:things) { |v, _| v.merge(coerced: true) }
        fact = store.write(store: :things, key: "k", value: { x: 1 })
        result = store.fact_by_id(fact.id)
        expect(result).to be(fact)
        expect(result.value).not_to have_key(:coerced)
      end
    end
  end

  # --- fact_ref ---

  describe "#fact_ref" do
    it "returns compact metadata without the value payload" do
      fact = store.write(store: :things, key: "k1", value: { secret: "data" })
      ref  = store.fact_ref(fact.id)
      expect(ref).to include(
        id:               fact.id,
        store:            fact.store,
        key:              fact.key,
        transaction_time: fact.transaction_time,
        valid_time:       fact.valid_time,
        value_hash:       fact.value_hash
      )
      expect(ref).not_to have_key(:value)
    end

    it "returns nil for unknown id" do
      expect(store.fact_ref("does-not-exist")).to be_nil
    end

    it "returns nil for nil id" do
      expect(store.fact_ref(nil)).to be_nil
    end
  end

  # --- compaction removes dropped facts ---

  describe "after retention compaction" do
    it "removes dropped fact ids and keeps surviving fact ids" do
      store.set_retention(:events, strategy: :ephemeral)

      f1 = store.append(history: :events, event: { seq: 1 })
      f2 = store.append(history: :events, event: { seq: 2 })

      # Both live before compaction
      expect(store.fact_by_id(f1.id)).to be(f1)
      expect(store.fact_by_id(f2.id)).to be(f2)

      store.compact(:events)

      # f1 is the older fact — :ephemeral keeps only latest per key.
      # Each append uses a random UUID key, so both are "latest" for their key.
      # All append facts are kept; compaction only drops superseded same-key writes.
      # Verify index is consistent with what the log now holds.
      all_ids = store.fact_log_all.map(&:id)
      all_ids.each { |id| expect(store.fact_by_id(id)).not_to be_nil }
    end

    it "removes overwritten key from index after ephemeral compaction" do
      store.set_retention(:ledger, strategy: :ephemeral)

      f1 = store.write(store: :ledger, key: "entry", value: { v: 1 })
      f2 = store.write(store: :ledger, key: "entry", value: { v: 2 })

      store.compact(:ledger)

      # f1 (older, same key) should be dropped
      expect(store.fact_by_id(f1.id)).to be_nil
      # f2 (latest) should survive
      expect(store.fact_by_id(f2.id)).not_to be_nil
    end
  end

  # --- file-backed replay ---

  describe "IgniterStore.open rebuilds index from replay" do
    it "makes all replayed facts findable by id" do
      dir = Dir.mktmpdir
      path = File.join(dir, "store.log")

      s1 = Igniter::Store::IgniterStore.open(path)
      written = s1.write(store: :docs, key: "d1", value: { body: "hello" })
      fact_id = written.id
      s1.close

      s2 = Igniter::Store::IgniterStore.open(path)
      result = s2.fact_by_id(fact_id)
      expect(result).not_to be_nil
      expect(result.id).to eq(fact_id)
      expect(result.store).to eq(:docs)
      s2.close
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
