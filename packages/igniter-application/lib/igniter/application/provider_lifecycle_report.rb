# frozen_string_literal: true

module Igniter
  module Application
    class ProviderLifecycleReport
      attr_reader :phase, :results

      def initialize(phase:, results:)
        @phase = phase.to_sym
        @results = Array(results).dup.freeze
        freeze
      end

      def provider_names
        results.map(&:provider_name)
      end

      def completed_provider_names
        results.select(&:completed?).map(&:provider_name)
      end

      def failed_provider_names
        results.select(&:failed?).map(&:provider_name)
      end

      def skipped_provider_names
        results.select(&:skipped?).map(&:provider_name)
      end

      def service_names
        results.flat_map(&:service_names).uniq.sort
      end

      def interface_names
        results.flat_map(&:interface_names).uniq.sort
      end

      def failed?
        results.any?(&:failed?)
      end

      def completed?
        !results.empty? && results.all?(&:completed?)
      end

      def skipped?
        results.empty? || results.all?(&:skipped?)
      end

      def status
        return :failed if failed?
        return :skipped if skipped?

        :completed
      end

      def to_h
        {
          phase: phase,
          status: status,
          providers: provider_names,
          completed_providers: completed_provider_names,
          failed_providers: failed_provider_names,
          skipped_providers: skipped_provider_names,
          services: service_names,
          interfaces: interface_names,
          results: results.map(&:to_h)
        }
      end
    end
  end
end
