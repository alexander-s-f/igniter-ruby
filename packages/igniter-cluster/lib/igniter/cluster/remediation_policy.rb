# frozen_string_literal: true

module Igniter
  module Cluster
    class RemediationPolicy
      DEFAULT_ACTIONS = {
        degraded_health: :retry_failover,
        lease: :reissue_lease,
        ownership_shift: :reconcile_ownership,
        rebalance: :retry_rebalance
      }.freeze

      attr_reader :name, :action_map, :metadata

      def initialize(name:, action_map: DEFAULT_ACTIONS, metadata: {})
        @name = name.to_sym
        @action_map = action_map.to_h.each_with_object({}) do |(incident_kind, action), resolved|
          resolved[incident_kind.to_sym] = action.to_sym
        end.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.default(metadata: {})
        new(name: :default, metadata: metadata)
      end

      def plan(active_incidents:, metadata: {})
        entries = resolve_entries(active_incidents)
        steps = entries.filter_map { |entry| build_step(entry) }
        details = plan_metadata(entries, steps, metadata)

        if steps.empty?
          return RemediationPlan.new(
            mode: :idle,
            steps: [],
            metadata: details,
            explanation: DecisionExplanation.new(
              code: :remediation_idle,
              message: "no remediation steps planned",
              metadata: details
            )
          )
        end

        RemediationPlan.new(
          mode: :planned,
          steps: steps,
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :remediation_plan,
            message: "planned #{steps.length} remediation step(s)",
            metadata: details
          )
        )
      end

      def to_h
        {
          name: name,
          action_map: action_map.dup,
          metadata: metadata.dup
        }
      end

      private

      def resolve_entries(active_incidents)
        return active_incidents.entries if active_incidents.respond_to?(:entries)

        Array(active_incidents)
      end

      def build_step(entry)
        action = action_map[entry.incident.kind]
        return nil if action.nil?

        RemediationStep.new(
          incident_id: entry.id,
          incident_key: entry.incident_key,
          incident_kind: entry.incident.kind,
          target: entry.incident.targets.first || "unknown",
          action: action,
          owner_name: entry.incident.owner_names.first,
          source_name: entry.incident.source_names.first,
          destination_name: entry.incident.destination_names.first,
          metadata: {
            policy: name,
            severity: entry.incident.severity,
            resolution: entry.resolution
          },
          reason: DecisionExplanation.new(
            code: :"#{action}_remediation",
            message: remediation_message(action, entry),
            metadata: {
              incident_id: entry.id,
              incident_kind: entry.incident.kind,
              target: entry.incident.targets.first
            }
          )
        )
      end

      def plan_metadata(entries, steps, extra_metadata)
        {
          policy: to_h,
          active_incident_count: entries.length,
          active_incident_ids: entries.map(&:id),
          active_incident_keys: entries.map(&:incident_key),
          planned_action_kinds: steps.map(&:action).uniq
        }.merge(extra_metadata)
      end

      def remediation_message(action, entry)
        "#{action} for #{entry.incident.kind} on #{entry.incident.targets.first}"
      end
    end
  end
end
