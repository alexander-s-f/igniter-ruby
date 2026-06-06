# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Reactive Derivation" do
  subject(:store) { Igniter::Store::IgniterStore.new }

  describe "basic derivation" do
    it "writes a derived fact when a source fact is written" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "Buy milk" })
      expect(store.read(store: :summaries, key: "all")).to eq({ count: 1 })
    end

    it "updates the derived fact on each source write" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "Buy milk" })
      store.write(store: :tasks, key: "t2", value: { title: "Send email" })
      expect(store.read(store: :summaries, key: "all")).to eq({ count: 2 })
    end

    it "does not affect the source store" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "Buy milk" })
      expect(store.read(store: :tasks, key: "t1")).to eq({ title: "Buy milk" })
    end
  end

  describe "source_filters" do
    it "counts only facts matching the filter" do
      store.register_derivation(
        source_store: :tasks, source_filters: { status: :open },
        target_store: :summaries, target_key: "open_count",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { status: :open })
      store.write(store: :tasks, key: "t2", value: { status: :done })
      store.write(store: :tasks, key: "t3", value: { status: :open })

      expect(store.read(store: :summaries, key: "open_count")).to eq({ count: 2 })
    end

    it "re-evaluates when a fact transitions out of filter" do
      store.register_derivation(
        source_store: :tasks, source_filters: { status: :open },
        target_store: :summaries, target_key: "open_count",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { status: :open })
      expect(store.read(store: :summaries, key: "open_count")).to eq({ count: 1 })

      store.write(store: :tasks, key: "t1", value: { status: :done })
      expect(store.read(store: :summaries, key: "open_count")).to eq({ count: 0 })
    end
  end

  describe "callable target_key" do
    it "derives the target key from source facts" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries,
        target_key: ->(facts) { "count_#{facts.size}" },
        rule: ->(facts) { { total: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "A" })
      expect(store.read(store: :summaries, key: "count_1")).to eq({ total: 1 })
    end
  end

  describe "nil rule result" do
    it "skips the derived write when rule returns nil" do
      store.register_derivation(
        source_store: :tasks, source_filters: { status: :open },
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { facts.empty? ? nil : { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { status: :done })
      expect(store.read(store: :summaries, key: "all")).to be_nil
    end
  end

  describe "cycle protection" do
    it "does not re-trigger derivation when writing the derived fact" do
      writes_to_target = 0
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) {
          writes_to_target += 1
          { count: facts.size }
        }
      )

      store.write(store: :tasks, key: "t1", value: { title: "A" })
      expect(writes_to_target).to eq(1)
    end

    it "does not loop when target_store == source_store" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :tasks, target_key: "derived",
        rule: ->(_facts) { { synthetic: true } }
      )

      expect { store.write(store: :tasks, key: "t1", value: { title: "A" }) }.not_to raise_error
      expect(store.read(store: :tasks, key: "derived")).to eq({ synthetic: true })
    end
  end

  describe "multiple derivations on the same source store" do
    it "fires all registered rules" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :counts, target_key: "total",
        rule: ->(facts) { { n: facts.size } }
      )
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :titles, target_key: "list",
        rule: ->(facts) { { items: facts.map { |f| f.value[:title] } } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "Buy milk" })

      expect(store.read(store: :counts, key: "total")).to eq({ n: 1 })
      expect(store.read(store: :titles, key: "list")).to eq({ items: ["Buy milk"] })
    end
  end

  describe "store isolation" do
    it "does not trigger derivation for an unrelated store write" do
      fired = false
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(_facts) { fired = true; { ok: true } }
      )

      store.write(store: :reminders, key: "r1", value: { title: "Check email" })
      expect(fired).to be false
    end
  end

  describe "fact_count" do
    it "counts both source and derived facts" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: "all",
        rule: ->(facts) { { count: facts.size } }
      )

      store.write(store: :tasks, key: "t1", value: { title: "A" })
      expect(store.fact_count).to eq(2)
    end
  end

  describe "SchemaGraph#derivation_snapshot" do
    it "returns compact metadata for registered derivations" do
      store.register_derivation(
        source_store: :tasks, source_filters: { status: :open },
        target_store: :summaries, target_key: "open_count",
        rule: ->(facts) { { count: facts.size } }
      )

      snapshot = store.schema_graph.derivation_snapshot
      expect(snapshot.length).to eq(1)
      expect(snapshot.first).to include(
        source_store: :tasks,
        source_filters: { status: :open },
        target_store: :summaries,
        target_key: "open_count",
        has_rule: true
      )
    end

    it "marks callable target_key in snapshot" do
      store.register_derivation(
        source_store: :tasks, source_filters: {},
        target_store: :summaries, target_key: ->(facts) { "key_#{facts.size}" },
        rule: ->(facts) { { n: facts.size } }
      )
      snapshot = store.schema_graph.derivation_snapshot
      expect(snapshot.first[:target_key]).to eq(:callable)
    end
  end
end
