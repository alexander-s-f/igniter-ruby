# frozen_string_literal: true

module Igniter
  module Application
    class ShutdownReport
      attr_reader :phases, :host_result, :scheduler_result, :provider_shutdown_report, :snapshot, :plan

      def initialize(phases:, host_result:, scheduler_result:, provider_shutdown_report:, snapshot:, plan:)
        @phases = phases.dup.freeze
        @host_result = host_result
        @scheduler_result = scheduler_result
        @provider_shutdown_report = provider_shutdown_report
        @snapshot = snapshot
        @plan = plan
        freeze
      end

      def scheduler_stopped?
        phase_completed?(:stop_scheduler)
      end

      def providers_shutdown?
        phase_completed?(:shutdown_providers)
      end

      def transport_deactivated?
        phase_completed?(:deactivate_transport)
      end

      def actions
        phases.select(&:completed?).map(&:name)
      end

      def to_h
        {
          phases: phases.map(&:to_h),
          actions: actions,
          plan: plan.to_h,
          host: host_result.to_h,
          scheduler: scheduler_result.to_h,
          provider_shutdown: provider_shutdown_report.to_h,
          snapshot: snapshot.to_h
        }
      end

      private

      def phase_completed?(name)
        phase = phases.find { |entry| entry.name == name.to_sym }
        phase&.completed? == true
      end
    end
  end
end
