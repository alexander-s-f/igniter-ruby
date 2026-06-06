# frozen_string_literal: true

module Igniter
  module Store
    class SchemaGraph
      def initialize
        @paths       = Hash.new { |hash, key| hash[key] = [] }
        @projections = {}
        @derivations = []
        @scatters    = []
        @relations   = {}
        @retention   = {}
        # Raw protocol descriptor storage (OP2 — metadata export)
        @store_descriptors        = {}
        @history_descriptors      = {}
        @command_descriptors      = {}
        @effect_descriptors       = {}
        @subscription_descriptors = {}
      end

      def register(path)
        @paths[path.store] << path
        self
      end

      def paths_for(store)
        @paths[store].dup
      end

      def consumers_for(store)
        @paths[store].flat_map { |path| path.consumers.to_a }.uniq
      end

      def path_for(store:, scope:)
        @paths[store].find { |path| path.scope == scope }
      end

      def registered_stores
        @paths.keys
      end

      # --- Projection registry ---

      def register_projection(projection_path)
        @projections[projection_path.name] = projection_path
        self
      end

      def projection_for(name:)
        @projections[name]
      end

      # All projections whose reads list includes the given store.
      def projections_for_store(store:)
        @projections.values.select { |p| p.reads.include?(store) }
      end

      # Compact snapshot of all registered projections, keyed by name.
      # Parallel to metadata_snapshot for access paths.
      def projection_snapshot
        @projections.transform_values do |p|
          {
            name:           p.name,
            reads:          p.reads,
            relations:      p.relations,
            consumer_hint:  p.consumer_hint,
            reactive:       p.reactive,
            store_count:    p.reads.size,
            relation_count: p.relations.size
          }
        end
      end

      # --- Derivation registry ---

      def register_derivation(derivation_rule)
        @derivations << derivation_rule
        self
      end

      # All derivation rules whose source_store matches the given store.
      def derivations_for_store(store:)
        @derivations.select { |r| r.source_store == store }
      end

      # Compact snapshot of registered derivation rules (rule callables omitted).
      def derivation_snapshot
        @derivations.map.with_index do |r, i|
          {
            index:          i,
            source_store:   r.source_store,
            source_filters: r.source_filters,
            target_store:   r.target_store,
            target_key:     r.target_key.respond_to?(:call) ? :callable : r.target_key,
            has_rule:       true
          }
        end
      end

      # --- Scatter Derivation registry ---

      def register_scatter(scatter_rule)
        @scatters << scatter_rule
        self
      end

      # All scatter rules whose source_store matches the given store.
      def scatters_for_store(store:)
        @scatters.select { |r| r.source_store == store }
      end

      # Compact snapshot of registered scatter rules (rule callables omitted).
      def scatter_snapshot
        @scatters.map.with_index do |r, i|
          {
            index:        i,
            source_store: r.source_store,
            partition_by: r.partition_by,
            target_store: r.target_store,
            has_rule:     true
          }
        end
      end

      # --- Relation registry ---

      def register_relation(relation_rule)
        @relations[relation_rule.name] = relation_rule
        self
      end

      def relation_for(name:)
        @relations[name]
      end

      def registered_relations
        @relations.keys
      end

      # Compact snapshot of all registered relations (no callables — pure metadata).
      def relation_snapshot
        @relations.transform_values do |r|
          {
            name:      r.name,
            source:    r.source,
            partition: r.partition,
            target:    r.target,
            index_store: :"__rel_#{r.name}"
          }
        end
      end

      # --- Retention registry ---

      def register_retention(store, policy)
        @retention[store] = policy
        self
      end

      # Returns the RetentionPolicy for store, or nil (meaning :permanent / no compaction).
      def retention_for(store:)
        @retention[store]
      end

      # Stores with an explicitly registered retention policy (any strategy).
      def retention_stores
        @retention.keys
      end

      # Compact snapshot of all registered retention policies.
      def retention_snapshot
        @retention.transform_values { |p| { strategy: p.strategy, duration: p.duration } }
      end

      # --- Raw descriptor storage (OP2 — metadata export) ---

      def register_store_descriptor(descriptor)
        @store_descriptors[descriptor[:name].to_sym] = descriptor
        self
      end

      def register_history_descriptor(descriptor)
        @history_descriptors[descriptor[:name].to_sym] = descriptor
        self
      end

      def register_subscription_descriptor(descriptor)
        @subscription_descriptors[descriptor[:name].to_sym] = descriptor
        self
      end

      def register_command_descriptor(descriptor)
        owner = descriptor[:owner].to_sym
        name = descriptor[:name].to_sym
        @command_descriptors[owner] ||= {}
        @command_descriptors[owner][name] = descriptor
        self
      end

      def register_effect_descriptor(descriptor)
        owner = descriptor[:owner].to_sym
        name = descriptor[:name].to_sym
        @effect_descriptors[owner] ||= {}
        @effect_descriptors[owner][name] = descriptor
        self
      end

      def command_snapshot
        @command_descriptors
      end

      def effect_snapshot
        @effect_descriptors
      end

      # Snapshot of all raw protocol-level descriptors registered via OP1.
      def descriptor_snapshot
        {
          stores:        @store_descriptors,
          histories:     @history_descriptors,
          commands:      @command_descriptors,
          effects:       @effect_descriptors,
          subscriptions: @subscription_descriptors
        }
      end

      # Returns a compact snapshot of all registered access paths keyed by store.
      # Each entry describes how the engine routes scope queries for that store:
      # scope name, lookup strategy, active filters, cache TTL, and consumer count.
      # Index descriptors (which fields are co-indexed) remain manifest/facade
      # metadata — they are a schema contract, not an engine routing concern.
      def metadata_snapshot
        @paths.each_with_object({}) do |(store, paths), snapshot|
          snapshot[store] = paths.map do |path|
            {
              store:          path.store,
              scope:          path.scope,
              lookup:         path.lookup,
              filters:        path.filters,
              cache_ttl:      path.cache_ttl,
              consumer_count: path.consumers.to_a.size
            }
          end
        end
      end
    end
  end
end
