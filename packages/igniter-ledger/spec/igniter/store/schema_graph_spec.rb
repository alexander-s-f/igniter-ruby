# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Store::SchemaGraph do
  def make_path(store:, scope:, lookup: :scope_index, filters: {}, cache_ttl: nil, consumers: [])
    Igniter::Store::AccessPath.new(
      store: store, scope: scope, lookup: lookup,
      filters: filters, cache_ttl: cache_ttl, consumers: Set.new(consumers)
    )
  end

  def make_projection(name:, reads:, relations: [], consumer_hint: :contract_node, reactive: false)
    Igniter::Store::ProjectionPath.new(
      name: name, reads: reads, relations: relations,
      consumer_hint: consumer_hint, reactive: reactive
    )
  end

  subject(:graph) { described_class.new }

  describe "#register / #paths_for" do
    it "returns registered paths for a store" do
      path = make_path(store: :tasks, scope: :open)
      graph.register(path)
      expect(graph.paths_for(:tasks)).to eq([path])
    end

    it "returns an empty array for an unknown store" do
      expect(graph.paths_for(:unknown)).to eq([])
    end

    it "returns a copy, not the live array" do
      path = make_path(store: :tasks, scope: :open)
      graph.register(path)
      graph.paths_for(:tasks) << make_path(store: :tasks, scope: :closed)
      expect(graph.paths_for(:tasks).size).to eq(1)
    end

    it "supports multiple paths per store" do
      p1 = make_path(store: :tasks, scope: :open)
      p2 = make_path(store: :tasks, scope: :closed)
      graph.register(p1).register(p2)
      expect(graph.paths_for(:tasks)).to contain_exactly(p1, p2)
    end

    it "is chainable" do
      path = make_path(store: :tasks, scope: :open)
      expect(graph.register(path)).to be(graph)
    end
  end

  describe "#consumers_for" do
    it "collects unique consumers across all paths for a store" do
      p1 = make_path(store: :tasks, scope: :open,   consumers: [:a, :b])
      p2 = make_path(store: :tasks, scope: :closed, consumers: [:b, :c])
      graph.register(p1).register(p2)
      expect(graph.consumers_for(:tasks)).to contain_exactly(:a, :b, :c)
    end

    it "returns empty array when no paths are registered" do
      expect(graph.consumers_for(:tasks)).to eq([])
    end
  end

  describe "#path_for" do
    it "finds a path by store and scope" do
      p1 = make_path(store: :tasks, scope: :open)
      p2 = make_path(store: :tasks, scope: :closed)
      graph.register(p1).register(p2)
      expect(graph.path_for(store: :tasks, scope: :open)).to be(p1)
    end

    it "returns nil when no match" do
      expect(graph.path_for(store: :tasks, scope: :open)).to be_nil
    end
  end

  describe "#registered_stores" do
    it "returns all stores with at least one registered path" do
      graph.register(make_path(store: :tasks,     scope: :open))
      graph.register(make_path(store: :reminders, scope: :open))
      expect(graph.registered_stores).to contain_exactly(:tasks, :reminders)
    end

    it "returns an empty array when nothing is registered" do
      expect(graph.registered_stores).to eq([])
    end
  end

  describe "#metadata_snapshot" do
    it "returns an empty hash when nothing is registered" do
      expect(graph.metadata_snapshot).to eq({})
    end

    it "includes one entry per store" do
      graph.register(make_path(store: :tasks,     scope: :open))
      graph.register(make_path(store: :reminders, scope: :open))
      expect(graph.metadata_snapshot.keys).to contain_exactly(:tasks, :reminders)
    end

    it "captures scope, lookup, filters, cache_ttl, and consumer_count" do
      path = make_path(
        store: :tasks, scope: :open,
        lookup: :scope_index, filters: { status: :open },
        cache_ttl: 60, consumers: [:a, :b]
      )
      graph.register(path)
      entry = graph.metadata_snapshot[:tasks].first
      expect(entry).to eq(
        store: :tasks, scope: :open, lookup: :scope_index,
        filters: { status: :open }, cache_ttl: 60, consumer_count: 2
      )
    end

    it "includes all paths for a store, not just the first" do
      graph.register(make_path(store: :tasks, scope: :open,   consumers: [:a]))
      graph.register(make_path(store: :tasks, scope: :closed, consumers: []))
      entries = graph.metadata_snapshot[:tasks]
      expect(entries.size).to eq(2)
      expect(entries.map { |e| e[:scope] }).to contain_exactly(:open, :closed)
    end

    it "reports consumer_count 0 when consumers is empty" do
      graph.register(make_path(store: :tasks, scope: :open, consumers: []))
      entry = graph.metadata_snapshot[:tasks].first
      expect(entry[:consumer_count]).to eq(0)
    end

    it "does not expose the consumers set itself (engine routing concern only)" do
      graph.register(make_path(store: :tasks, scope: :open, consumers: [:a]))
      entry = graph.metadata_snapshot[:tasks].first
      expect(entry).not_to have_key(:consumers)
    end
  end

  describe "#register_projection / #projection_for / #projections_for_store" do
    it "stores and retrieves a projection by name" do
      proj = make_projection(name: :tracker_read_model, reads: [:trackers, :tracker_logs])
      graph.register_projection(proj)
      expect(graph.projection_for(name: :tracker_read_model)).to be(proj)
    end

    it "returns nil for an unregistered projection name" do
      expect(graph.projection_for(name: :unknown)).to be_nil
    end

    it "is chainable" do
      proj = make_projection(name: :tracker_read_model, reads: [:trackers])
      expect(graph.register_projection(proj)).to be(graph)
    end

    it "finds projections reading from a given store" do
      p1 = make_projection(name: :tracker_read_model, reads: [:trackers, :tracker_logs])
      p2 = make_projection(name: :countdown_read_model, reads: [:countdowns])
      graph.register_projection(p1).register_projection(p2)
      expect(graph.projections_for_store(store: :trackers)).to contain_exactly(p1)
      expect(graph.projections_for_store(store: :tracker_logs)).to contain_exactly(p1)
      expect(graph.projections_for_store(store: :countdowns)).to contain_exactly(p2)
    end

    it "returns empty array when no projections read from the given store" do
      expect(graph.projections_for_store(store: :unknown)).to eq([])
    end
  end

  describe "#projection_snapshot" do
    it "returns empty hash when no projections are registered" do
      expect(graph.projection_snapshot).to eq({})
    end

    it "keys snapshot by projection name" do
      graph.register_projection(make_projection(name: :tracker_read_model, reads: [:trackers]))
      graph.register_projection(make_projection(name: :countdown_read_model, reads: [:countdowns]))
      expect(graph.projection_snapshot.keys).to contain_exactly(:tracker_read_model, :countdown_read_model)
    end

    it "captures all descriptor fields and derived counts" do
      proj = make_projection(
        name: :tracker_read_model,
        reads: [:trackers, :tracker_logs],
        relations: [:tracker_logs_by_tracker],
        consumer_hint: :contract_node,
        reactive: true
      )
      graph.register_projection(proj)
      entry = graph.projection_snapshot[:tracker_read_model]
      expect(entry).to eq(
        name:           :tracker_read_model,
        reads:          [:trackers, :tracker_logs],
        relations:      [:tracker_logs_by_tracker],
        consumer_hint:  :contract_node,
        reactive:       true,
        store_count:    2,
        relation_count: 1
      )
    end

    it "records store_count and relation_count as integers" do
      graph.register_projection(make_projection(name: :activity_feed, reads: [:actions], relations: []))
      entry = graph.projection_snapshot[:activity_feed]
      expect(entry[:store_count]).to eq(1)
      expect(entry[:relation_count]).to eq(0)
    end
  end

  describe "#command_snapshot / #effect_snapshot" do
    it "stores command descriptors grouped by owner" do
      graph.register_command_descriptor(
        name: :complete,
        owner: :reminders,
        operation: :record_update,
        target_shape: :store,
        boundary: :app
      )

      expect(graph.command_snapshot[:reminders][:complete]).to include(
        operation: :record_update,
        target_shape: :store,
        boundary: :app
      )
    end

    it "stores effect descriptors grouped by owner" do
      graph.register_effect_descriptor(
        name: :complete,
        owner: :reminders,
        store_op: :store_write,
        write_kind: :update,
        lowers_to: :store_t,
        boundary: :app
      )

      expect(graph.effect_snapshot[:reminders][:complete]).to include(
        store_op: :store_write,
        write_kind: :update,
        lowers_to: :store_t,
        boundary: :app
      )
    end

    it "includes command and effect registries in descriptor_snapshot" do
      graph.register_command_descriptor(name: :complete, owner: :reminders, operation: :record_update)
      graph.register_effect_descriptor(name: :complete, owner: :reminders, store_op: :store_write, write_kind: :update)

      snapshot = graph.descriptor_snapshot

      expect(snapshot[:commands][:reminders]).to have_key(:complete)
      expect(snapshot[:effects][:reminders]).to have_key(:complete)
    end
  end
end
