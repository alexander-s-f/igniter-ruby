# frozen_string_literal: true

module Igniter
  module Cluster
    class PeerDiscovery
      attr_reader :metadata

      def initialize(metadata: {})
        @metadata = metadata.dup.freeze
        freeze
      end

      def peers_for(plan_kind:, plan:, action:, membership:)
        ordered_names = ordered_candidate_names(plan_kind: plan_kind, plan: plan, action: action)
        discovered = ordered_names.filter_map { |name| membership.fetch(name) }
        query = query_for(plan)
        discovered |= membership.select(query: query) unless query.nil?
        discovered.freeze
      end

      def to_h
        {
          metadata: metadata.dup
        }
      end

      private

      def ordered_candidate_names(plan_kind:, plan:, action:)
        names = []

        case plan_kind.to_sym
        when :rebalance
          names << action.destination.name
          names.concat(Array(plan.metadata[:destination_names]))
        when :ownership
          names << action.owner.name
          names.concat(Array(plan.metadata[:candidate_owner_names]))
        when :lease
          names << action.owner.name
          names.concat(Array(plan.metadata.dig(:ownership, :owner_names)))
        when :failover
          names << action.destination.name
          names.concat(Array(plan.metadata[:destination_names]))
          names.concat(Array(plan.metadata.dig(:ownership, :owner_names)))
        end

        names.map(&:to_sym).uniq
      end

      def query_for(plan)
        query_hash =
          plan.metadata[:query] ||
          plan.metadata.dig(:ownership, :metadata, :query)

        return nil unless query_hash.is_a?(Hash)

        CapabilityQuery.from_routing(query_hash)
      end
    end
  end
end
