# frozen_string_literal: true

module Igniter
  module Application
    class PlanExecutor
      attr_reader :environment

      def initialize(environment:)
        @environment = environment
      end

      def boot(plan)
        phases = []

        loader_result = execute_boot_load_code_step(plan.load_code_step, base_dir: plan.base_dir)
        phases << BootPhase.new(name: :load_code, status: loader_result.status)

        resolution_report = environment.send(:resolve_providers!)
        phases << BootPhase.new(name: :resolve_providers, status: resolution_report.status)

        provider_boot_report = environment.send(:boot_providers!)
        phases << BootPhase.new(name: :boot_providers, status: provider_boot_report.status)

        scheduler_result = execute_step(plan.scheduler_step)
        phases << BootPhase.new(name: :start_scheduler, status: scheduler_result.status)

        host_result = execute_step(plan.host_step)
        phases << BootPhase.new(name: :activate_transport, status: host_result.status)

        environment.send(:mark_booted!)
        BootReport.new(
          base_dir: plan.base_dir,
          phases: phases,
          loader_result: loader_result,
          scheduler_result: scheduler_result,
          host_result: host_result,
          provider_resolution_report: resolution_report,
          provider_boot_report: provider_boot_report,
          snapshot: environment.snapshot,
          plan: plan
        )
      end

      def shutdown(plan)
        phases = []

        host_result = execute_step(plan.host_step)
        phases << BootPhase.new(name: :deactivate_transport, status: host_result.status)

        scheduler_result = execute_step(plan.scheduler_step)
        phases << BootPhase.new(name: :stop_scheduler, status: scheduler_result.status)

        provider_shutdown_report = environment.send(:shutdown_providers!)
        phases << BootPhase.new(name: :shutdown_providers, status: provider_shutdown_report.status)

        environment.send(:mark_shutdown!)
        ShutdownReport.new(
          phases: phases,
          host_result: host_result,
          scheduler_result: scheduler_result,
          provider_shutdown_report: provider_shutdown_report,
          snapshot: environment.snapshot,
          plan: plan
        )
      end

      private

      def execute_boot_load_code_step(step, base_dir:)
        return environment.send(:skipped_seam_result_from_step, step) unless step.planned?

        environment.send(:load_code_with_report, base_dir: base_dir)
      end

      def execute_step(step)
        return environment.send(:skipped_seam_result_from_step, step) unless step.planned?

        case [step.seam_name, step.action]
        when %i[scheduler start]
          environment.send(:start_scheduler_with_report)
        when %i[scheduler stop]
          environment.send(:stop_scheduler_with_report)
        when %i[host activate_transport]
          environment.send(:activate_transport_with_report)
        when %i[host deactivate_transport]
          environment.send(:deactivate_transport_with_report)
        else
          raise ArgumentError, "unsupported lifecycle plan step #{step.seam_name}:#{step.action}"
        end
      end
    end
  end
end
