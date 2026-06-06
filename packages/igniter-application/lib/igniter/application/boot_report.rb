# frozen_string_literal: true

module Igniter
  module Application
    class BootReport
      attr_reader :base_dir, :phases, :loader_result, :scheduler_result, :host_result,
                  :provider_resolution_report, :provider_boot_report, :snapshot, :plan

      def initialize(base_dir:, phases:, loader_result:, scheduler_result:, host_result:,
                     provider_resolution_report:, provider_boot_report:, snapshot:, plan:)
        @base_dir = base_dir
        @phases = phases.dup.freeze
        @loader_result = loader_result
        @scheduler_result = scheduler_result
        @host_result = host_result
        @provider_resolution_report = provider_resolution_report
        @provider_boot_report = provider_boot_report
        @snapshot = snapshot
        @plan = plan
        freeze
      end

      def loaded_code?
        phase_completed?(:load_code)
      end

      def providers_resolved?
        phase_completed?(:resolve_providers)
      end

      def providers_booted?
        phase_completed?(:boot_providers)
      end

      def scheduler_started?
        phase_completed?(:start_scheduler)
      end

      def transport_activated?
        phase_completed?(:activate_transport)
      end

      def actions
        phases.select(&:completed?).map(&:name)
      end

      def to_h
        {
          base_dir: base_dir,
          phases: phases.map(&:to_h),
          actions: actions,
          plan: plan.to_h,
          loader: loader_result.to_h,
          scheduler: scheduler_result.to_h,
          host: host_result.to_h,
          provider_resolution: provider_resolution_report.to_h,
          provider_boot: provider_boot_report.to_h,
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
