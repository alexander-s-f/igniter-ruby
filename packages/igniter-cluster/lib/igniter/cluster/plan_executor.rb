# frozen_string_literal: true

module Igniter
  module Cluster
    class PlanExecutor
      attr_reader :environment, :incident_executor

      def initialize(environment:)
        @environment = environment
        @incident_executor = IncidentExecutor.new(metadata: { scope: :plan_execution })
      end

      def execute(plan, handler: nil, metadata: {})
        case plan
        when RebalancePlan
          execute_rebalance(plan, handler: handler, metadata: metadata)
        when OwnershipPlan
          execute_ownership(plan, handler: handler, metadata: metadata)
        when LeasePlan
          execute_lease(plan, handler: handler, metadata: metadata)
        when FailoverPlan
          execute_failover(plan, handler: handler, metadata: metadata)
        when RemediationPlan
          execute_remediation(plan, handler: handler, metadata: metadata)
        else
          raise ArgumentError, "unsupported cluster plan #{plan.class}"
        end
      end

      def execute_rebalance(plan, handler: nil, metadata: {})
        execute_action_plan(
          plan_kind: :rebalance,
          plan: plan,
          actions: plan.moves,
          handler: handler,
          metadata: metadata
        )
      end

      def execute_ownership(plan, handler: nil, metadata: {})
        execute_action_plan(
          plan_kind: :ownership,
          plan: plan,
          actions: plan.claims,
          handler: handler,
          metadata: metadata
        )
      end

      def execute_lease(plan, handler: nil, metadata: {})
        execute_action_plan(
          plan_kind: :lease,
          plan: plan,
          actions: plan.grants,
          handler: handler,
          metadata: metadata
        )
      end

      def execute_failover(plan, handler: nil, metadata: {})
        execute_action_plan(
          plan_kind: :failover,
          plan: plan,
          actions: plan.steps,
          handler: handler,
          metadata: metadata
        )
      end

      def execute_remediation(plan, handler: nil, metadata: {})
        report = execute_action_plan(
          plan_kind: :remediation,
          plan: plan,
          actions: plan.steps,
          handler: handler,
          metadata: metadata,
          record_incident: false
        )
        persist_remediation_workflow_actions(report)
        report
      end

      private

      def execute_action_plan(plan_kind:, plan:, actions:, handler:, metadata:, record_incident: true)
        action_results = Array(actions).map do |action|
          resolve_action_result(plan_kind: plan_kind, action: action, handler: handler)
        end

        status = derive_status(action_results)
        details = {
          plan_mode: plan.mode,
          action_count: action_results.length,
          cluster_profile: environment.profile.to_h
        }.merge(metadata)
        incident_artifacts = incident_artifacts_for(
          record_incident: record_incident,
          plan_kind: plan_kind,
          plan: plan,
          action_results: action_results,
          status: status,
          metadata: metadata
        )

        report = PlanExecutionReport.new(
          plan_kind: plan_kind,
          status: status,
          plan: plan,
          action_results: action_results,
          incident: incident_artifacts.fetch(:incident),
          recovery_timeline: incident_artifacts.fetch(:recovery_timeline),
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :"#{plan_kind}_execution",
            message: execution_message(plan_kind, status, action_results.length),
            metadata: details
          )
        )
        persist_incident_entry(report, details) if record_incident
        report
      end

      def resolve_action_result(plan_kind:, action:, handler:)
        return default_action_result(plan_kind: plan_kind, action: action) if handler.nil?

        resolved = handler.call(plan_kind: plan_kind, action: action, environment: environment)
        return resolved if resolved.is_a?(PlanActionResult)

        metadata =
          case resolved
          when Hash
            resolved
          else
            { handler_result: resolved }
          end

        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: :completed,
          subject: subject_for(plan_kind, action),
          metadata: metadata.merge(simulated: false, action: action.to_h),
          explanation: DecisionExplanation.new(
            code: :"#{plan_kind}_action_executed",
            message: execution_action_message(plan_kind, action),
            metadata: metadata
          )
        )
      rescue StandardError => e
        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: :failed,
          subject: subject_for(plan_kind, action),
          metadata: {
            simulated: false,
            action: action.to_h,
            error: {
              class: e.class.name,
              message: e.message
            }
          },
          explanation: DecisionExplanation.new(
            code: :"#{plan_kind}_action_failed",
            message: "failed to execute #{plan_kind} action",
            metadata: {
              error_class: e.class.name
            }
          )
        )
      end

      def default_action_result(plan_kind:, action:)
        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: action.to_h.empty? ? :skipped : :completed,
          subject: subject_for(plan_kind, action),
          metadata: {
            simulated: true,
            action: action.to_h
          },
          explanation: DecisionExplanation.new(
            code: :"#{plan_kind}_action_simulated",
            message: execution_action_message(plan_kind, action),
            metadata: {
              simulated: true
            }
          )
        )
      end

      def action_type_for(plan_kind)
        :"#{plan_kind}_action"
      end

      def derive_status(action_results)
        return :skipped if action_results.empty?
        return :failed if action_results.any?(&:failed?)
        return :skipped if action_results.all?(&:skipped?)

        :completed
      end

      def execution_message(plan_kind, status, count)
        case status
        when :completed
          "executed #{count} #{plan_kind} action(s)"
        when :failed
          "failed while executing #{plan_kind} actions"
        else
          "no #{plan_kind} actions executed"
        end
      end

      def execution_action_message(plan_kind, action)
        case plan_kind
        when :rebalance
          "rebalance #{action.source.name} to #{action.destination.name}"
        when :ownership
          "assign #{action.target} to #{action.owner.name}"
        when :lease
          "grant lease for #{action.target} to #{action.owner.name}"
        when :failover
          "fail over #{action.target} from #{action.source.name} to #{action.destination.name}"
        when :remediation
          "run #{action.action} for #{action.incident_kind} on #{action.target}"
        else
          "execute #{plan_kind} action"
        end
      end

      def subject_for(plan_kind, action)
        case plan_kind
        when :rebalance
          {
            source: action.source.name,
            destination: action.destination.name
          }
        when :ownership
          {
            target: action.target,
            owner: action.owner.name
          }
        when :lease
          {
            target: action.target,
            owner: action.owner.name
          }
        when :failover
          {
            target: action.target,
            source: action.source.name,
            destination: action.destination.name
          }
        when :remediation
          {
            incident_id: action.incident_id,
            incident_kind: action.incident_kind,
            target: action.target,
            action: action.action
          }
        else
          action.to_h
        end
      end

      def incident_artifacts_for(record_incident:, plan_kind:, plan:, action_results:, status:, metadata:)
        return { incident: nil, recovery_timeline: nil } unless record_incident

        incident_executor.execute(
          plan_kind: plan_kind,
          plan: plan,
          action_results: action_results,
          status: status,
          metadata: metadata
        )
      end

      def persist_incident_entry(report, details)
        return report if report.incident.nil?

        environment.incident_registry.record(report, metadata: details)
        report
      end

      def persist_remediation_workflow_actions(report)
        report.action_results.each do |result|
          subject = result.subject
          next unless subject.is_a?(Hash) && subject[:incident_id]

          environment.incident_registry.record_action(
            subject.fetch(:incident_id),
            kind: remediation_action_kind(result.status),
            status: result.status,
            metadata: {
              remediation_action: subject[:action],
              remediation_target: subject[:target],
              action_result: result.to_h
            }
          )
        end
      end

      def remediation_action_kind(status)
        case status.to_sym
        when :completed
          :remediation_completed
        when :failed
          :remediation_failed
        else
          :remediation_skipped
        end
      end
    end
  end
end
