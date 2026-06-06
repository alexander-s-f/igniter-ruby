# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Scatter Derivation (Belt 8)" do
  subject(:store) { Igniter::Store::IgniterStore.new }

  # Helper: the classic "Article has many Comments" index rule.
  # rule.(article_id, existing_index, new_comment_fact) → { ids: [...], count: N }
  let(:comment_index_rule) do
    lambda do |article_id, existing, new_fact|
      ids = existing ? existing[:ids].dup : []
      ids << new_fact.id unless ids.include?(new_fact.id)
      { article_id: article_id, ids: ids, count: ids.size }
    end
  end

  # ------------------------------------------------------------------ struct

  describe "ScatterRule struct" do
    it "is constructable with all fields" do
      rule = Igniter::Store::ScatterRule.new(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )
      expect(rule.source_store).to eq(:comments)
      expect(rule.partition_by).to eq(:article_id)
      expect(rule.target_store).to eq(:article_comment_index)
      expect(rule.rule).to respond_to(:call)
    end
  end

  # ------------------------------------------------------------------ SchemaGraph

  describe "SchemaGraph scatter registry" do
    it "registers and retrieves scatter rules for a store" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )
      rules = store.schema_graph.scatters_for_store(store: :comments)
      expect(rules.size).to eq(1)
      expect(rules.first.partition_by).to eq(:article_id)
    end

    it "returns empty array for unregistered store" do
      expect(store.schema_graph.scatters_for_store(store: :unknown)).to be_empty
    end

    it "scatter_snapshot omits the rule callable" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )
      snap = store.schema_graph.scatter_snapshot
      expect(snap.size).to eq(1)
      expect(snap.first).to include(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        has_rule:     true
      )
      expect(snap.first).not_to have_key(:rule)
    end

    it "is chainable" do
      result = store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )
      expect(result).to be(store)
    end
  end

  # ------------------------------------------------------------------ basic scatter

  describe "basic scatter trigger" do
    before do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )
    end

    it "writes a derived index fact when a comment is written" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "Hello" })
      index = store.read(store: :article_comment_index, key: "a1")
      expect(index).not_to be_nil
      expect(index[:count]).to eq(1)
    end

    it "accumulates multiple comments for the same article" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "First" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1", body: "Second" })
      index = store.read(store: :article_comment_index, key: "a1")
      expect(index[:count]).to eq(2)
    end

    it "creates separate index entries for different articles" do
      store.write(store: :comments, key: "c1", value: { article_id: "a1", body: "For A1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a2", body: "For A2" })
      expect(store.read(store: :article_comment_index, key: "a1")[:count]).to eq(1)
      expect(store.read(store: :article_comment_index, key: "a2")[:count]).to eq(1)
    end
  end

  # ------------------------------------------------------------------ partition extraction

  describe "partition key extraction" do
    it "uses the partition_by field from the source fact's value as target key" do
      store.register_scatter(
        source_store: :tasks,
        partition_by: :project_id,
        target_store: :project_task_index,
        rule:         ->(pid, existing, f) { { project_id: pid, task_ids: ((existing || {})[:task_ids] || []) + [f.key] } }
      )

      store.write(store: :tasks, key: "t1", value: { project_id: "p42", title: "Setup" })
      index = store.read(store: :project_task_index, key: "p42")
      expect(index[:task_ids]).to include("t1")
    end

    it "skips facts whose value does not contain the partition_by field" do
      store.register_scatter(
        source_store: :events,
        partition_by: :user_id,
        target_store: :user_event_index,
        rule:         ->(_uid, existing, _f) { { count: ((existing || {})[:count] || 0) + 1 } }
      )

      store.write(store: :events, key: "e1", value: { type: :login })     # no user_id
      store.write(store: :events, key: "e2", value: { user_id: "u1", type: :logout })

      expect(store.read(store: :user_event_index, key: "u1")[:count]).to eq(1)
      # No spurious nil-keyed entry
      expect(store.read(store: :user_event_index, key: "")).to be_nil
    end
  end

  # ------------------------------------------------------------------ existing value passed

  describe "existing value passed to rule" do
    it "receives nil existing when index entry does not yet exist" do
      received_existing = :not_set

      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         lambda { |_pk, existing, _f|
          received_existing = existing
          { count: 1 }
        }
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      expect(received_existing).to be_nil
    end

    it "receives the current index value on subsequent writes" do
      values_seen = []

      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         lambda { |_pk, existing, _f|
          values_seen << existing
          { count: (existing || { count: 0 })[:count] + 1 }
        }
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1" })

      expect(values_seen[0]).to be_nil
      expect(values_seen[1]).to eq({ count: 1 })
    end
  end

  # ------------------------------------------------------------------ nil rule result

  describe "rule returning nil" do
    it "skips the write when rule returns nil" do
      store.register_scatter(
        source_store: :events,
        partition_by: :user_id,
        target_store: :user_event_index,
        rule:         ->(_pk, _existing, _f) { nil }
      )

      store.write(store: :events, key: "e1", value: { user_id: "u1" })
      expect(store.read(store: :user_event_index, key: "u1")).to be_nil
    end
  end

  # ------------------------------------------------------------------ cycle protection

  describe "cycle protection" do
    it "does not re-trigger scatter when target_store == source_store" do
      call_count = 0
      store.register_scatter(
        source_store: :index,
        partition_by: :group_id,
        target_store: :index,          # same store — potential cycle
        rule:         lambda { |_pk, existing, _f|
          call_count += 1
          { count: ((existing || {})[:count] || 0) + 1 }
        }
      )

      store.write(store: :index, key: "i1", value: { group_id: "g1" })
      # Should fire exactly once — the scatter-triggered write is blocked by the flag
      expect(call_count).to eq(1)
    end
  end

  # ------------------------------------------------------------------ store isolation

  describe "store isolation" do
    it "does not fire scatter for unregistered source stores" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )

      store.write(store: :reactions, key: "r1", value: { article_id: "a1", emoji: ":+" })
      expect(store.read(store: :article_comment_index, key: "a1")).to be_nil
    end
  end

  # ------------------------------------------------------------------ multiple rules

  describe "multiple scatter rules on the same source store" do
    it "fires all matching rules independently" do
      store.register_scatter(
        source_store: :tasks,
        partition_by: :project_id,
        target_store: :project_task_index,
        rule:         ->(_pk, e, f) { { ids: ((e || {})[:ids] || []) + [f.key] } }
      )
      store.register_scatter(
        source_store: :tasks,
        partition_by: :assignee_id,
        target_store: :assignee_task_index,
        rule:         ->(_pk, e, f) { { ids: ((e || {})[:ids] || []) + [f.key] } }
      )

      store.write(store: :tasks, key: "t1", value: { project_id: "p1", assignee_id: "u1", title: "Do it" })

      expect(store.read(store: :project_task_index,  key: "p1")[:ids]).to include("t1")
      expect(store.read(store: :assignee_task_index, key: "u1")[:ids]).to include("t1")
    end
  end

  # ------------------------------------------------------------------ fact_count

  describe "fact_count after scatter" do
    it "includes the scatter-derived index facts in the total fact count" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a2" })

      # 2 comments + 2 index entries (one per unique article)
      expect(store.fact_count).to eq(4)
    end

    it "accumulation replaces rather than appends: count grows with index updates" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1" })

      # 2 comments + 2 index versions (one per write to article_comment_index)
      # The latest index read reflects accumulated count
      expect(store.read(store: :article_comment_index, key: "a1")[:count]).to eq(2)
    end
  end

  # ------------------------------------------------------------------ causation chain on index

  describe "causation chain on the scatter index" do
    it "builds a causation chain across index updates for the same article" do
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1" })

      chain = store.causation_chain(store: :article_comment_index, key: "a1")
      expect(chain.size).to eq(2)
      expect(chain[0][:causation]).to be_nil
      expect(chain[1][:causation]).to eq(chain[0][:id])
    end
  end

  # ------------------------------------------------------------------ scatter + derivation interop

  describe "scatter and gather derivation coexist" do
    it "both fire on the same source write without interference" do
      # Gather: count all comments globally
      store.register_derivation(
        source_store: :comments, source_filters: {},
        target_store: :global_comment_count, target_key: "all",
        rule:         ->(facts) { { total: facts.size } }
      )
      # Scatter: per-article comment index
      store.register_scatter(
        source_store: :comments,
        partition_by: :article_id,
        target_store: :article_comment_index,
        rule:         comment_index_rule
      )

      store.write(store: :comments, key: "c1", value: { article_id: "a1" })
      store.write(store: :comments, key: "c2", value: { article_id: "a1" })

      expect(store.read(store: :global_comment_count, key: "all")[:total]).to eq(2)
      expect(store.read(store: :article_comment_index, key: "a1")[:count]).to eq(2)
    end
  end
end
