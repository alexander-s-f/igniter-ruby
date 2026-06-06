# frozen_string_literal: true

module Igniter
  module Cluster
    class IncidentExecutor
      attr_reader :metadata

      def initialize(metadata: {})
        @metadata = metadata.dup.freeze
        freeze
      end

      def execute(plan_kind:, plan:, action_results:, status:, metadata: {})
        incident = build_incident(plan_kind: plan_kind, plan: plan, status: status, metadata: metadata)
        recovery_timeline = build_recovery_timeline(
          incident: incident,
          plan_kind: plan_kind,
          action_results: action_results,
          status: status,
          metadata: metadata
        )

        {
          incident: incident,
          recovery_timeline: recovery_timeline
        }
      end

      private

      def build_incident(plan_kind:, plan:, status:, metadata:)
        kind = incident_kind_for(plan_kind)
        details = self.metadata.merge(metadata).merge(
          plan_kind: plan_kind,
          plan_mode: plan.mode
        )

        ClusterIncident.new(
          kind: kind,
          status: status,
          severity: severity_for(kind, status),
          targets: plan.respond_to?(:targets) ? plan.targets : [],
          source_names: plan.respond_to?(:source_names) ? plan.source_names : [],
          destination_names: plan.respond_to?(:destination_names) ? plan.destination_names : [],
          owner_names: plan.respond_to?(:owner_names) ? plan.owner_names : [],
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :"#{kind}_incident",
            message: incident_message(kind, status),
            metadata: details
          )
        )
      end

      def build_recovery_timeline(incident:, plan_kind:, action_results:, status:, metadata:)
        event_log = ClusterEventLog.new(
          events: [
            ClusterEvent.new(
              kind: :incident_detected,
              status: incident.status,
              metadata: {
                incident: incident.to_h,
                plan_kind: plan_kind
              }
            ),
            *Array(action_results).map.with_index do |action_result, index|
              ClusterEvent.new(
                kind: action_result.action_type,
                status: action_result.status,
                metadata: {
                  sequence: index + 1,
                  subject: action_result.subject,
                  explanation: action_result.explanation&.to_h
                }
              )
            end,
            ClusterEvent.new(
              kind: :recovery_outcome,
              status: recovery_status_for(status),
              metadata: {
                incident_kind: incident.kind,
                plan_kind: plan_kind,
                action_count: Array(action_results).length
              }
            )
          ],
          metadata: self.metadata.merge(metadata)
        )

        RecoveryTimeline.new(
          kind: incident.kind,
          status: status,
          event_log: event_log,
          metadata: self.metadata.merge(metadata),
          explanation: DecisionExplanation.new(
            code: :recovery_timeline,
            message: "recovery timeline captured #{event_log.event_count} event(s) for #{incident.kind}",
            metadata: {
              incident_kind: incident.kind,
              plan_kind: plan_kind,
              event_count: event_log.event_count
            }
          )
        )
      end

      def incident_kind_for(plan_kind)
        case plan_kind.to_sym
        when :ownership
          :ownership_shift
        when :lease
          :lease
        when :failover
          :degraded_health
        else
          :rebalance
        end
      end

      def severity_for(kind, status)
        return :critical if status.to_sym == :failed && kind == :degraded_health
        return :high if kind == :degraded_health
        return :high if kind == :lease && status.to_sym == :failed
        return :medium if %i[ownership_shift lease].include?(kind)

        :low
      end

      def incident_message(kind, status)
        "#{kind} incident is #{status}"
      end

      def recovery_status_for(status)
        case status.to_sym
        when :completed
          :recovered
        when :failed
          :unresolved
        else
          :stable
        end
      end
    end
  end
end
