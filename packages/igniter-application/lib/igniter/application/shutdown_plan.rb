# frozen_string_literal: true

module Igniter
  module Application
    class ShutdownPlan
      attr_reader :steps, :snapshot

      def initialize(steps:, snapshot:)
        @steps = steps.dup.freeze
        @snapshot = snapshot
        freeze
      end

      def host_step
        fetch_step(:deactivate_transport)
      end

      def scheduler_step
        fetch_step(:stop_scheduler)
      end

      def provider_shutdown_step
        fetch_step(:shutdown_providers)
      end

      def actions
        steps.select(&:planned?).map(&:name)
      end

      def to_h
        {
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
