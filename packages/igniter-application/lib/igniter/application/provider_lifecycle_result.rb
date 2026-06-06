# frozen_string_literal: true

module Igniter
  module Application
    class ProviderLifecycleResult
      attr_reader :provider_name, :phase, :status, :service_names, :interface_names, :error

      def initialize(provider_name:, phase:, status:, service_names: [], interface_names: [], error: nil)
        @provider_name = provider_name.to_sym
        @phase = phase.to_sym
        @status = status.to_sym
        @service_names = Array(service_names).map(&:to_sym).sort.freeze
        @interface_names = Array(interface_names).map(&:to_sym).sort.freeze
        @error = normalize_error(error)
        freeze
      end

      def completed?
        status == :completed
      end

      def failed?
        status == :failed
      end

      def skipped?
        status == :skipped
      end

      def to_h
        {
          provider: provider_name,
          phase: phase,
          status: status,
          services: service_names,
          interfaces: interface_names,
          error: error&.dup
        }
      end

      private

      def normalize_error(error)
        return nil if error.nil?
        return error.dup.freeze if error.is_a?(Hash)

        {
          class: error.class.name,
          message: error.message
        }.freeze
      end
    end
  end
end
