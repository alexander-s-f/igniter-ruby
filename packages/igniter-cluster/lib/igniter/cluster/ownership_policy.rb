# frozen_string_literal: true

module Igniter
  module Cluster
    class OwnershipPolicy
      attr_reader :name, :owner_limit, :use_topology_policy, :metadata

      def initialize(name:, owner_limit: 1, use_topology_policy: true, metadata: {})
        @name = name.to_sym
        @owner_limit = Integer(owner_limit)
        @use_topology_policy = use_topology_policy == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.distributed(metadata: {})
        new(name: :distributed, metadata: metadata)
      end

      def plan(peers:, query:, target:, topology_policy: nil, metadata: {})
        candidates = candidate_owners(peers: peers, query: query, topology_policy: topology_policy)

        if candidates.empty?
          return OwnershipPlan.new(
            mode: :unowned,
            claims: [],
            metadata: plan_metadata(query, target, candidates, metadata),
            explanation: DecisionExplanation.new(
              code: :unowned_target,
              message: "no owner available for #{target}",
              metadata: plan_metadata(query, target, candidates, metadata)
            )
          )
        end

        claims = candidates.first(owner_limit).map do |owner|
          OwnershipClaim.new(
            target: target,
            owner: owner,
            metadata: {
              policy: name,
              query: query.to_h
            },
            reason: DecisionExplanation.new(
              code: :ownership_assigned,
              message: "assign #{target} to #{owner.name}",
              metadata: {
                policy: name,
                target: target,
                owner: owner.name
              }
            )
          )
        end

        OwnershipPlan.new(
          mode: :assigned,
          claims: claims,
          metadata: plan_metadata(query, target, candidates, metadata),
          explanation: DecisionExplanation.new(
            code: :ownership_plan,
            message: "assigned #{target} to #{claims.length} owner(s)",
            metadata: plan_metadata(query, target, candidates, metadata)
          )
        )
      end

      def to_h
        {
          name: name,
          owner_limit: owner_limit,
          use_topology_policy: use_topology_policy,
          metadata: metadata.dup
        }
      end

      private

      def candidate_owners(peers:, query:, topology_policy:)
        candidates =
          if use_topology_policy && !topology_policy.nil?
            topology_policy.destinations_for(peers: peers, query: query)
          else
            Array(peers).select { |peer| query.matches_peer?(peer) }
          end

        candidates.select { |peer| query.matches_capabilities?(peer) }
      end

      def plan_metadata(query, target, candidates, extra_metadata)
        {
          policy: to_h,
          target: target.to_s,
          query: query.to_h,
          candidate_owner_names: candidates.map(&:name)
        }.merge(extra_metadata)
      end
    end
  end
end
