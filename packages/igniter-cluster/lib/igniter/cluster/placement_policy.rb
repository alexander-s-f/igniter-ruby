# frozen_string_literal: true

module Igniter
  module Cluster
    class PlacementPolicy
      attr_reader :name, :honor_preferred_peer, :filter_capabilities, :candidate_limit, :metadata

      def initialize(name:, honor_preferred_peer: true, filter_capabilities: false, candidate_limit: nil, metadata: {})
        @name = name.to_sym
        @honor_preferred_peer = honor_preferred_peer == true
        @filter_capabilities = filter_capabilities == true
        @candidate_limit = normalize_candidate_limit(candidate_limit)
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.direct(metadata: {})
        new(name: :direct, metadata: metadata)
      end

      def mode_for(query)
        return :pinned if honor_preferred_peer && query.pinned?
        return :capability_filtered if filter_capabilities && !query.required_capabilities.empty?
        return :intent_filtered if query.topology_constraints? || (filter_capabilities && !query.required_traits.empty?)

        :direct
      end

      def select_candidates(query:, peers:)
        candidates = Array(peers)
        candidates = filter_preferred_peer(query, candidates)
        candidates = filter_by_topology(query, candidates)
        candidates = filter_by_capabilities(query, candidates)
        candidates = limit_candidates(candidates)
        candidates.freeze
      end

      def explanation_for(query:, candidates:)
        case mode_for(query)
        when :pinned
          DecisionExplanation.new(
            code: :preferred_peer,
            message: "preferred peer=#{query.preferred_peer}",
            metadata: {
              preferred_peer: query.preferred_peer,
              policy: name
            }
          )
        when :capability_filtered
          DecisionExplanation.new(
            code: :capability_filtered_placement,
            message: "capability-filtered placement across #{candidates.length} peer(s)",
            metadata: {
              required_capabilities: query.required_capabilities,
              candidate_count: candidates.length,
              policy: name
            }
          )
        when :intent_filtered
          DecisionExplanation.new(
            code: :intent_filtered_placement,
            message: "intent-filtered placement across #{candidates.length} peer(s)",
            metadata: {
              required_traits: query.required_traits,
              required_labels: query.required_labels,
              preferred_region: query.preferred_region,
              preferred_zone: query.preferred_zone,
              candidate_count: candidates.length,
              policy: name
            }
          )
        else
          DecisionExplanation.new(
            code: :direct_placement,
            message: "direct placement across #{candidates.length} peer(s)",
            metadata: {
              candidate_count: candidates.length,
              policy: name
            }
          )
        end
      end

      def to_h
        {
          name: name,
          honor_preferred_peer: honor_preferred_peer,
          filter_capabilities: filter_capabilities,
          candidate_limit: candidate_limit,
          metadata: metadata.dup
        }
      end

      private

      def normalize_candidate_limit(candidate_limit)
        return nil if candidate_limit.nil?

        Integer(candidate_limit)
      end

      def filter_preferred_peer(query, candidates)
        return candidates unless honor_preferred_peer && query.pinned?

        candidates.select { |peer| peer.name == query.preferred_peer }
      end

      def filter_by_capabilities(query, candidates)
        return candidates unless filter_capabilities && query.capability_constraints?

        candidates.select do |peer|
          query.matches_capabilities?(peer)
        end
      end

      def filter_by_topology(query, candidates)
        return candidates unless query.topology_constraints?

        candidates.select do |peer|
          query.matches_topology?(peer)
        end
      end

      def limit_candidates(candidates)
        return candidates if candidate_limit.nil?

        candidates.first(candidate_limit)
      end
    end
  end
end
