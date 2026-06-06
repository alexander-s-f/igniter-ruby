# frozen_string_literal: true

module Igniter
  module Application
    class BootPlan
      attr_reader :base_dir, :steps, :snapshot

      def initialize(base_dir:, steps:, snapshot:)
        @base_dir = base_dir.to_s
        @steps = steps.dup.freeze
        @snapshot = snapshot
        freeze
      end

      def load_code_step
        fetch_step(:load_code)
      end

      def provider_resolution_step
        fetch_step(:resolve_providers)
      end

      def provider_boot_step
        fetch_step(:boot_providers)
      end

      def scheduler_step
        fetch_step(:start_scheduler)
      end

      def host_step
        fetch_step(:activate_transport)
      end

      def actions
        steps.select(&:planned?).map(&:name)
      end

      def to_h
        {
          base_dir: base_dir,
          phases: steps.map(&:to_h),
          actions: actions,
          snapshot: snapshot.to_h
        }
      end

      private

      def fetch_step(name)
        steps.find { |step| step.name == name.to_sym }
      end
    end
  end
end
