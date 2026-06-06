# frozen_string_literal: true

module Igniter
  module Cluster
    class TopologyPolicy
      attr_reader :name, :preferred_region, :preferred_zone, :required_labels,
                  :max_destinations, :metadata

      def initialize(name:, preferred_region: nil, preferred_zone: nil, required_labels: {}, max_destinations: nil,
                     metadata: {})
        @name = name.to_sym
        @preferred_region = preferred_region&.to_s
        @preferred_zone = preferred_zone&.to_s
        @required_labels = normalize_labels(required_labels)
        @max_destinations = max_destinations.nil? ? nil : Integer(max_destinations)
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.locality_aware(metadata: {})
        new(name: :locality_aware, metadata: metadata)
      end

      def destinations_for(peers:, query:)
        limited_destinations(select_destinations(peers, query))
      end

      def plan(peers:, query:, metadata: {})
        destinations = destinations_for(peers: peers, query: query)
        sources = select_sources(peers, destinations)

        if destinations.empty?
          return RebalancePlan.new(
            mode: :unsatisfied,
            moves: [],
            metadata: plan_metadata(query, sources, destinations, metadata),
            explanation: DecisionExplanation.new(
              code: :unsatisfied_topology,
              message: "no topology-compliant destinations available",
              metadata: plan_metadata(query, sources, destinations, metadata)
            )
          )
        end

        if sources.empty?
          return RebalancePlan.new(
            mode: :stable,
            moves: [],
            metadata: plan_metadata(query, sources, destinations, metadata),
            explanation: DecisionExplanation.new(
              code: :stable_topology,
              message: "cluster already satisfies topology policy #{name}",
              metadata: plan_metadata(query, sources, destinations, metadata)
            )
          )
        end

        moves = build_moves(sources, destinations, query)
        RebalancePlan.new(
          mode: :rebalance,
          moves: moves,
          metadata: plan_metadata(query, sources, destinations, metadata),
          explanation: DecisionExplanation.new(
            code: :topology_rebalance,
            message: "rebalance #{moves.length} source peer(s) toward #{destinations.length} destination peer(s)",
            metadata: plan_metadata(query, sources, destinations, metadata)
          )
        )
      end

      def to_h
        {
          name: name,
          preferred_region: preferred_region,
          preferred_zone: preferred_zone,
          required_labels: required_labels.dup,
          max_destinations: max_destinations,
          metadata: metadata.dup
        }
      end

      private

      def normalize_labels(labels)
        labels.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end

      def select_destinations(peers, query)
        effective_query = effective_query_for(query)
        Array(peers).select do |peer|
          effective_query.matches_topology?(peer)
        end
      end

      def limited_destinations(destinations)
        return destinations if max_destinations.nil?

        destinations.first(max_destinations)
      end

      def select_sources(peers, destinations)
        destination_names = destinations.map(&:name)
        Array(peers).reject { |peer| destination_names.include?(peer.name) }
      end

      def build_moves(sources, destinations, query)
        sources.each_with_index.map do |source, index|
          destination = destinations[index % destinations.length]
          RebalanceMove.new(
            source: source,
            destination: destination,
            metadata: {
              policy: name,
              query: query.to_h
            },
            reason: DecisionExplanation.new(
              code: :topology_move,
              message: "move workload from #{source.name} to #{destination.name}",
              metadata: {
                source: source.name,
                destination: destination.name,
                policy: name
              }
            )
          )
        end
      end

      def plan_metadata(query, sources, destinations, extra_metadata)
        {
          policy: to_h,
          query: effective_query_for(query).to_h,
          source_names: sources.map(&:name),
          destination_names: destinations.map(&:name)
        }.merge(extra_metadata)
      end

      def effective_query_for(query)
        CapabilityQuery.new(
          required_capabilities: query.required_capabilities,
          required_traits: query.required_traits,
          required_labels: required_labels.merge(query.required_labels),
          preferred_peer: query.preferred_peer,
          preferred_region: query.preferred_region || preferred_region,
          preferred_zone: query.preferred_zone || preferred_zone,
          metadata: query.metadata,
          capability_catalog: query.capability_catalog
        )
      end
    end
  end
end
