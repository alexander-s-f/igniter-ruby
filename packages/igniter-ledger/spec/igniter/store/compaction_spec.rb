# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Compaction (Belt 7a + 7b)" do
  subject(:store) { Igniter::Store::IgniterStore.new }

  # ------------------------------------------------------------------ Belt 7a

  describe "RetentionPolicy struct" do
    it "is constructable with strategy and optional duration" do
      p = Igniter::Store::RetentionPolicy.new(strategy: :rolling_window, duration: 3600.0)
      expect(p.strategy).to eq(:rolling_window)
      expect(p.duration).to eq(3600.0)
    end

    it "allows nil duration for :ephemeral" do
      p = Igniter::Store::RetentionPolicy.new(strategy: :ephemeral, duration: nil)
      expect(p.duration).to be_nil
    end
  end

  describe "#set_retention / SchemaGraph retention registry" do
    it "registers a policy and retrieves it via schema_graph" do
      store.set_retention(:sensors, strategy: :rolling_window, duration: 86_400.0)
      policy = store.schema_graph.retention_for(store: :sensors)
      expect(policy.strategy).to eq(:rolling_window)
      expect(policy.duration).to eq(86_400.0)
    end

    it "lists retention_stores" do
      store.set_retention(:sensors,  strategy: :ephemeral)
      store.set_retention(:readings, strategy: :rolling_window, duration: 3600.0)
      expect(store.schema_graph.retention_stores).to contain_exactly(:sensors, :readings)
    end

    it "returns retention_snapshot" do
      store.set_retention(:sensors, strategy: :ephemeral, duration: nil)
      snap = store.schema_graph.retention_snapshot
      expect(snap[:sensors]).to eq({ strategy: :ephemeral, duration: nil })
    end

    it "is chainable" do
      expect(store.set_retention(:sensors, strategy: :ephemeral)).to be(store)
    end
  end

  describe "compact — :ephemeral strategy" do
    it "keeps only the latest fact per key, drops historical" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.write(store: :sensors, key: "s1", value: { v: 3 })

      reports = store.compact
      expect(reports.first[:dropped_count]).to eq(2)
      expect(store.fact_count).to eq(2) # 1 kept + 1 receipt
    end

    it "preserves the current (latest) read after compaction" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 99 })
      store.compact
      expect(store.read(store: :sensors, key: "s1")).to eq({ v: 99 })
    end

    it "preserves latest per key for multiple keys" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.write(store: :sensors, key: "s2", value: { v: 10 })
      store.write(store: :sensors, key: "s2", value: { v: 20 })
      store.compact

      expect(store.read(store: :sensors, key: "s1")).to eq({ v: 2 })
      expect(store.read(store: :sensors, key: "s2")).to eq({ v: 20 })
    end

    it "does not touch unregistered stores" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors,  key: "s1", value: { v: 1 })
      store.write(store: :sensors,  key: "s1", value: { v: 2 })
      store.write(store: :payments, key: "p1", value: { amount: 100 })
      store.write(store: :payments, key: "p1", value: { amount: 200 })

      store.compact

      # payments untouched — full history still present
      chain = store.causation_chain(store: :payments, key: "p1")
      expect(chain.size).to eq(2)
    end

    it "does not compact when nothing to drop (single fact per key)" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      reports = store.compact
      expect(reports.first[:dropped_count]).to eq(0)
    end

    it "returns empty array when no stores with retention are registered" do
      expect(store.compact).to eq([])
    end
  end

  describe "compact — :rolling_window strategy" do
    # Uses real sleeps (≤120ms) — required because Fact timestamps are set by the
    # clock at write time and cannot be injected in native-extension mode.

    it "drops facts older than duration, keeps current and recent" do
      store.set_retention(:readings, strategy: :rolling_window, duration: 0.1)

      store.write(store: :readings, key: "r1", value: { v: 1 })
      store.write(store: :readings, key: "r1", value: { v: 2 })
      sleep 0.12  # age out of the 100ms window

      store.write(store: :readings, key: "r1", value: { v: 3 })  # within window
      store.write(store: :readings, key: "r1", value: { v: 4 })  # current

      store.compact
      expect(store.read(store: :readings, key: "r1")).to eq({ v: 4 })

      chain = store.causation_chain(store: :readings, key: "r1")
      # v:3 (within window) + v:4 (current) — 2 kept, 2 dropped
      expect(chain.size).to eq(2)
    end

    it "always keeps the current fact even if older than window" do
      store.set_retention(:readings, strategy: :rolling_window, duration: 0.01)

      store.write(store: :readings, key: "r1", value: { v: 1 })
      sleep 0.02  # age past the 10ms window

      store.compact
      expect(store.read(store: :readings, key: "r1")).to eq({ v: 1 })
    end

    it "reports dropped_count correctly" do
      store.set_retention(:readings, strategy: :rolling_window, duration: 0.1)

      store.write(store: :readings, key: "r1", value: { v: 1 })
      store.write(store: :readings, key: "r1", value: { v: 2 })
      sleep 0.12

      store.write(store: :readings, key: "r1", value: { v: 3 })

      reports = store.compact
      expect(reports.first[:dropped_count]).to eq(2)
      expect(reports.first[:kept_count]).to    eq(1)
    end
  end

  describe "compact — :permanent strategy" do
    it "never compacts permanent stores" do
      store.set_retention(:payments, strategy: :permanent)
      store.write(store: :payments, key: "p1", value: { amount: 100 })
      store.write(store: :payments, key: "p1", value: { amount: 200 })
      store.compact
      expect(store.causation_chain(store: :payments, key: "p1").size).to eq(2)
    end
  end

  describe "compact(store) — single store target" do
    it "compacts only the specified store" do
      store.set_retention(:sensors,  strategy: :ephemeral)
      store.set_retention(:readings, strategy: :ephemeral)
      store.write(store: :sensors,  key: "s1", value: { v: 1 })
      store.write(store: :sensors,  key: "s1", value: { v: 2 })
      store.write(store: :readings, key: "r1", value: { v: 1 })
      store.write(store: :readings, key: "r1", value: { v: 2 })

      store.compact(:sensors)

      # sensors compacted
      expect(store.causation_chain(store: :sensors, key: "s1").size).to eq(1)
      # readings untouched
      expect(store.causation_chain(store: :readings, key: "r1").size).to eq(2)
    end
  end

  # ------------------------------------------------------------------ Belt 7b

  describe "compaction receipt (Belt 7b)" do
    it "writes a receipt to :__compaction_receipts meta-store" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.compact

      receipts = store.compaction_receipts
      expect(receipts.size).to eq(1)
    end

    it "receipt value contains compaction metadata" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.compact

      receipt = store.compaction_receipts.first
      value = receipt.value
      expect(value[:type]).to            eq(:compaction_receipt)
      expect(value[:compacted_store]).to eq(:sensors)
      expect(value[:strategy]).to        eq(:ephemeral)
      expect(value[:compacted_count]).to eq(1)
      expect(value[:oldest_dropped]).to  be_a(String)  # fact id
      expect(value[:newest_dropped]).to  be_a(String)
      expect(value[:compacted_at]).to    be_a(Float)
    end

    it "report includes the receipt_id" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })

      reports = store.compact
      receipts = store.compaction_receipts
      expect(reports.first[:receipt_id]).to eq(receipts.first.id)
    end

    it "no receipt when nothing was dropped" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.compact
      expect(store.compaction_receipts).to be_empty
    end

    it "accumulates receipts across multiple compact calls" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.compact
      store.write(store: :sensors, key: "s1", value: { v: 3 })
      store.compact
      expect(store.compaction_receipts.size).to eq(2)
    end

    it "compaction_receipts(store:) filters by compacted_store" do
      store.set_retention(:sensors,  strategy: :ephemeral)
      store.set_retention(:readings, strategy: :ephemeral)
      store.write(store: :sensors,  key: "s1", value: { v: 1 })
      store.write(store: :sensors,  key: "s1", value: { v: 2 })
      store.write(store: :readings, key: "r1", value: { v: 1 })
      store.write(store: :readings, key: "r1", value: { v: 2 })
      store.compact

      expect(store.compaction_receipts(store: :sensors).size).to  eq(1)
      expect(store.compaction_receipts(store: :readings).size).to eq(1)
      expect(store.compaction_receipts.size).to                    eq(2)
    end
  end

  describe "post-compaction invariants" do
    it "fact_count includes only kept + receipt facts" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.write(store: :sensors, key: "s1", value: { v: 3 })
      store.compact
      # 1 kept sensor + 1 receipt
      expect(store.fact_count).to eq(2)
    end

    it "schema_graph (paths, projections, derivations) survives rebuild" do
      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :sensors, scope: :hot, lookup: :scope_index,
          filters: { active: true }, cache_ttl: nil, consumers: Set.new
        )
      )
      store.set_retention(:sensors, strategy: :ephemeral)
      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.compact

      # Schema graph is NOT rebuilt — it lives on @schema_graph, not in the log
      expect(store.schema_graph.path_for(store: :sensors, scope: :hot)).not_to be_nil
    end

    it "derivations still fire after compaction" do
      store.set_retention(:sensors, strategy: :ephemeral)
      store.register_derivation(
        source_store: :sensors, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :sensors, key: "s1", value: { v: 1 })
      store.write(store: :sensors, key: "s1", value: { v: 2 })
      store.compact

      store.write(store: :sensors, key: "s2", value: { v: 3 })
      expect(store.read(store: :summaries, key: "all")).to eq({ count: 2 })
    end
  end
end
