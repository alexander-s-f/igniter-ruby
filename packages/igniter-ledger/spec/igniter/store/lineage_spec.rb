# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Causal Proof / Lineage API" do
  subject(:store) { Igniter::Store::IgniterStore.new }

  describe "#lineage structure" do
    it "returns subject, chain, depth, derived_by, and proof_hash" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      result = store.lineage(store: :tasks, key: "t1")
      expect(result.keys).to contain_exactly(:subject, :chain, :depth, :derived_by, :proof_hash)
    end

    it "sets subject to store and key" do
      result = store.lineage(store: :tasks, key: "t1")
      expect(result[:subject]).to eq({ store: :tasks, key: "t1" })
    end
  end

  describe "empty chain" do
    it "returns empty chain for unknown key" do
      result = store.lineage(store: :tasks, key: "unknown")
      expect(result[:chain]).to be_empty
      expect(result[:depth]).to eq(0)
    end

    it "returns nil proof_hash when chain is empty" do
      result = store.lineage(store: :tasks, key: "unknown")
      expect(result[:proof_hash]).to be_nil
    end
  end

  describe "chain content" do
    it "captures all facts for the key in chronological order" do
      f1 = store.write(store: :tasks, key: "t1", value: { v: 1 })
      f2 = store.write(store: :tasks, key: "t1", value: { v: 2 })
      chain = store.lineage(store: :tasks, key: "t1")[:chain]
      expect(chain.map { |e| e[:id] }).to eq([f1.id, f2.id])
    end

    it "includes all required fields per chain entry" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      entry = store.lineage(store: :tasks, key: "t1")[:chain].first
      expect(entry.keys).to contain_exactly(
        :id, :store, :key, :causation, :value_hash, :transaction_time, :valid_time, :schema_version
      )
    end

    it "carries causation links between consecutive facts" do
      f1 = store.write(store: :tasks, key: "t1", value: { v: 1 })
      _f2 = store.write(store: :tasks, key: "t1", value: { v: 2 })
      chain = store.lineage(store: :tasks, key: "t1")[:chain]
      expect(chain[0][:causation]).to be_nil
      expect(chain[1][:causation]).to eq(f1.id)
    end

    it "does not include facts from other keys in the same store" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      store.write(store: :tasks, key: "t2", value: { v: 2 })
      chain = store.lineage(store: :tasks, key: "t1")[:chain]
      expect(chain.size).to eq(1)
      expect(chain.first[:key]).to eq("t1")
    end

    it "depth equals chain length" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      store.write(store: :tasks, key: "t1", value: { v: 2 })
      result = store.lineage(store: :tasks, key: "t1")
      expect(result[:depth]).to eq(result[:chain].size)
    end
  end

  describe "proof_hash" do
    it "is a 64-character hex string (SHA256)" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      hash = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      expect(hash).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is stable for the same chain" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      h1 = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      h2 = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      expect(h1).to eq(h2)
    end

    it "changes when a new fact is appended" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      h1 = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      store.write(store: :tasks, key: "t1", value: { v: 2 })
      h2 = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      expect(h1).not_to eq(h2)
    end

    it "differs for different keys even with same value" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      store.write(store: :tasks, key: "t2", value: { v: 1 })
      h1 = store.lineage(store: :tasks, key: "t1")[:proof_hash]
      h2 = store.lineage(store: :tasks, key: "t2")[:proof_hash]
      expect(h1).not_to eq(h2)
    end
  end

  describe "derived_by" do
    it "is empty when no derivations are registered" do
      store.write(store: :tasks, key: "t1", value: { v: 1 })
      expect(store.lineage(store: :tasks, key: "t1")[:derived_by]).to be_empty
    end

    it "lists derivation rules for this store" do
      store.register_derivation(
        source_store: :tasks, source_filters: { status: :open },
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )
      derived_by = store.lineage(store: :tasks, key: "t1")[:derived_by]
      expect(derived_by.size).to eq(1)
      expect(derived_by.first).to include(
        target_store: :summaries,
        target_key: "all",
        source_filters: { status: :open }
      )
    end

    it "marks callable target_key as :callable" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: ->(facts) { "k_#{facts.size}" },
        rule: ->(facts) { { n: facts.size } }
      )
      derived_by = store.lineage(store: :tasks, key: "t1")[:derived_by]
      expect(derived_by.first[:target_key]).to eq(:callable)
    end

    it "does not include derivations for other source stores" do
      store.register_derivation(
        source_store: :reminders, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(_) { { ok: true } }
      )
      derived_by = store.lineage(store: :tasks, key: "t1")[:derived_by]
      expect(derived_by).to be_empty
    end
  end
end
