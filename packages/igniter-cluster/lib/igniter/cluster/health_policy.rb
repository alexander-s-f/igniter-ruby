# frozen_string_literal: true

module Igniter
  module Cluster
    class HealthPolicy
      attr_reader :name, :trigger_statuses, :allow_degraded_owners, :metadata

      def initialize(name:, trigger_statuses: %i[degraded unhealthy], allow_degraded_owners: false, metadata: {})
        @name = name.to_sym
        @trigger_statuses = Array(trigger_statuses).map(&:to_sym).uniq.sort.freeze
        @allow_degraded_owners = allow_degraded_owners == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.availability_aware(metadata: {})
        new(name: :availability_aware, metadata: metadata)
      end

      def plan(peers:, query:, target:, ownership_policy:, topology_policy:, metadata: {})
        relevant_peers = Array(peers).select { |peer| query.matches_peer?(peer) }
        triggered_peers = relevant_peers.select { |peer| trigger_statuses.include?(peer.health.status) }

        if triggered_peers.empty?
          details = plan_metadata(query, target, triggered_peers, [], metadata)
          return FailoverPlan.new(
            mode: :stable,
            steps: [],
            metadata: details,
            explanation: DecisionExplanation.new(
              code: :stable_health,
              message: "no failover required for #{target}",
              metadata: details
            )
          )
        end

        healthy_peers = Array(peers).select { |peer| peer.health.available?(allow_degraded: allow_degraded_owners) }
        ownership_plan = ownership_policy.plan(
          peers: healthy_peers,
          query: query,
          target: target,
          topology_policy: topology_policy,
          metadata: { source: :health_policy }
        )

        if ownership_plan.claims.empty?
          details = plan_metadata(query, target, triggered_peers, [], metadata).merge(
            ownership: ownership_plan.to_h
          )
          return FailoverPlan.new(
            mode: :unrecoverable,
            steps: [],
            metadata: details,
            explanation: DecisionExplanation.new(
              code: :unrecoverable_failover,
              message: "no healthy failover destination for #{target}",
              metadata: details
            )
          )
        end

        destination = ownership_plan.claims.first.owner
        steps = triggered_peers.map do |source|
          FailoverStep.new(
            target: target,
            source: source,
            destination: destination,
            metadata: {
              policy: name,
              ownership: ownership_plan.to_h
            },
            reason: DecisionExplanation.new(
              code: :failover_assignment,
              message: "fail over #{target} from #{source.name} to #{destination.name}",
              metadata: {
                target: target.to_s,
                source: source.name,
                destination: destination.name,
                source_status: source.health.status,
                policy: name
              }
            )
          )
        end

        details = plan_metadata(query, target, triggered_peers, [destination], metadata).merge(
          ownership: ownership_plan.to_h
        )
        FailoverPlan.new(
          mode: :failover,
          steps: steps,
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :failover_plan,
            message: "planned failover for #{target} across #{steps.length} source peer(s)",
            metadata: details
          )
        )
      end

      def to_h
        {
          name: name,
          trigger_statuses: trigger_statuses.dup,
          allow_degraded_owners: allow_degraded_owners,
          metadata: metadata.dup
        }
      end

      private

      def plan_metadata(query, target, sources, destinations, extra_metadata)
        {
          policy: to_h,
          target: target.to_s,
          query: query.to_h,
          source_names: sources.map(&:name),
          destination_names: destinations.map(&:name)
        }.merge(extra_metadata)
      end
    end
  end
end
