# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "RelationRule DSL (Belt 9)" do
  subject(:store) { Igniter::Store::IgniterStore.new }

  # ------------------------------------------------------------------ struct

  describe "RelationRule struct" do
    it "is constructable with all fields" do
      rule = Igniter::Store::RelationRule.new(
        name:      :article_comments,
        source:    :comments,
        partition: :article_id,
        target:    :articles
      )
      expect(rule.name).to      eq(:article_comments)
      expect(rule.source).to    eq(:comments)
      expect(rule.partition).to eq(:article_id)
      expect(rule.target).to    eq(:articles)
    end
  end

  # ------------------------------------------------------------------ SchemaGraph

  describe "SchemaGraph relation registry" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "registers and retrieves a relation by name" do
      rule = store.schema_graph.relation_for(name: :article_comments)
      expect(rule).not_to be_nil
      expect(rule.source).to    eq(:comments)
      expect(rule.partition).to eq(:article_id)
      expect(rule.target).to    eq(:articles)
    end

    it "returns nil for unknown relation" do
      expect(store.schema_graph.relation_for(name: :unknown)).to be_nil
    end

    it "lists registered_relations" do
      store.register_relation(:project_tasks,
        source: :tasks, partition: :project_id, target: :projects)
      expect(store.schema_graph.registered_relations).to contain_exactly(
        :article_comments, :project_tasks
      )
    end

    it "relation_snapshot includes all metadata fields" do
      snap = store.schema_graph.relation_snapshot
      expect(snap[:article_comments]).to include(
        name:        :article_comments,
        source:      :comments,
        partition:   :article_id,
        target:      :articles,
        index_store: :__rel_article_comments
      )
    end
  end

  # ------------------------------------------------------------------ register_relation is chainable

  describe "#register_relation chainability" do
    it "returns the store" do
      result = store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
      expect(result).to be(store)
    end
  end

  # ------------------------------------------------------------------ basic resolve

  describe "#resolve — basic" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "returns empty array when no facts written yet" do
      expect(store.resolve(:article_comments, from: "a1")).to eq([])
    end

    it "returns the source value after one write" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "Hello" })
      result = store.resolve(:article_comments, from: "a1")
      expect(result).to eq([{ article_id: "a1", body: "Hello" }])
    end

    it "accumulates multiple source facts for the same partition value" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "First" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1", body: "Second" })
      result = store.resolve(:article_comments, from: "a1")
      expect(result.size).to eq(2)
      expect(result.map { |v| v[:body] }).to contain_exactly("First", "Second")
    end

    it "separates entries for different partition values" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "For A1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a2", body: "For A2" })
      expect(store.resolve(:article_comments, from: "a1").size).to eq(1)
      expect(store.resolve(:article_comments, from: "a2").size).to eq(1)
    end

    it "returns empty array for a partition value with no matching facts" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      expect(store.resolve(:article_comments, from: "a99")).to eq([])
    end
  end

  # ------------------------------------------------------------------ resolve returns latest value

  describe "#resolve — returns latest value per key" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "returns the latest value when a source fact is updated" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "v1" })
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "v2" })
      result = store.resolve(:article_comments, from: "a1")
      expect(result.size).to   eq(1)
      expect(result.first[:body]).to eq("v2")
    end

    it "does not deduplicate: each unique key appears exactly once" do
      3.times { |i| store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "v#{i}" }) }
      expect(store.resolve(:article_comments, from: "a1").size).to eq(1)
    end
  end

  # ------------------------------------------------------------------ unknown relation

  describe "#resolve — unknown relation" do
    it "raises ArgumentError for an unregistered relation name" do
      expect { store.resolve(:nonexistent, from: "x") }
        .to raise_error(ArgumentError, /No relation registered/)
    end
  end

  # ------------------------------------------------------------------ partition field missing

  describe "#resolve — source facts without partition field" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "ignores source facts that have no partition field" do
      store.write(store: :comments, key: "c1", value: { body: "no article_id here" })
      expect(store.resolve(:article_comments, from: "")).to eq([])
    end
  end

  # ------------------------------------------------------------------ multiple relations

  describe "multiple relations on the same source store" do
    it "maintains independent indexes" do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
      store.register_relation(:user_comments,
        source: :comments, partition: :user_id, target: :users)

      store.write(store: :comments, key: "c1",
                  value: { article_id: "a1", user_id: "u1", body: "Hi" })

      expect(store.resolve(:article_comments, from: "a1").size).to eq(1)
      expect(store.resolve(:user_comments,    from: "u1").size).to eq(1)
    end
  end

  # ------------------------------------------------------------------ relation + gather coexistence

  describe "relation and gather derivation coexist" do
    it "both maintain their derived state independently" do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
      store.register_derivation(
        source_store: :comments, source_filters: {},
        target_store: :global_stats, target_key: "all",
        rule: ->(facts) { { total: facts.size } }
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "One" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1", body: "Two" })

      expect(store.resolve(:article_comments, from: "a1").size).to eq(2)
      expect(store.read(store: :global_stats, key: "all")[:total]).to eq(2)
    end
  end

  # ------------------------------------------------------------------ relation index causation

  describe "causation chain on the relation index" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "builds a causation chain on the index as comments accumulate" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1" })
      chain = store.causation_chain(store: :__rel_article_comments, key: "a1")
      expect(chain.size).to eq(2)
      expect(chain[1][:causation]).to eq(chain[0][:id])
    end
  end

  # ------------------------------------------------------------------ schema_graph snapshot in lineage

  describe "relation_snapshot in schema context" do
    it "appears in schema_graph after registration" do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
      snap = store.schema_graph.relation_snapshot
      expect(snap.keys).to include(:article_comments)
    end

    it "scatter_snapshot also reflects the auto-registered scatter rule" do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
      scatter = store.schema_graph.scatter_snapshot
      expect(scatter.any? { |s| s[:source_store] == :comments }).to be true
    end
  end

  # ------------------------------------------------------------------ time-travel resolve (as_of:)

  describe "#resolve with as_of:" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "returns the relation state at a past point in time" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "Early" })
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(store: :comments, key: "c2", value: { article_id: "a1", body: "Later" })

      past    = store.resolve(:article_comments, from: "a1", as_of: checkpoint)
      current = store.resolve(:article_comments, from: "a1")

      expect(past.size).to    eq(1)
      expect(past.first[:body]).to eq("Early")
      expect(current.size).to eq(2)
    end

    it "returns [] when nothing was indexed before as_of" do
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "Post-checkpoint" })

      expect(store.resolve(:article_comments, from: "a1", as_of: checkpoint)).to eq([])
    end

    it "reflects updated source values at the past timestamp" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "v1" })
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "v2" })

      past = store.resolve(:article_comments, from: "a1", as_of: checkpoint)
      expect(past.first[:body]).to eq("v1")
    end
  end

  # ------------------------------------------------------------------ G-Set property

  describe "G-Set (append-only) property" do
    before do
      store.register_relation(:article_comments,
        source: :comments, partition: :article_id, target: :articles)
    end

    it "once indexed, a key never disappears from resolve" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "old" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1", body: "new" })
      # c1 is still resolved (latest value of c1)
      result = store.resolve(:article_comments, from: "a1")
      expect(result.map { |v| v[:body] }).to contain_exactly("old", "new")
    end
  end
end
