# frozen_string_literal: true

module Igniter
  module Application
    class FlowDeclaration
      attr_reader :name, :purpose, :initial_status, :current_step, :pending_inputs,
                  :pending_actions, :artifacts, :contracts, :services, :interfaces,
                  :surfaces, :exports, :imports, :metadata

      def initialize(name:, purpose: nil, initial_status: :active, current_step: nil,
                     pending_inputs: [], pending_actions: [], artifacts: [],
                     contracts: [], services: [], interfaces: [], surfaces: [],
                     exports: [], imports: [], metadata: {})
        @name = name.to_sym
        @purpose = purpose&.to_s
        @initial_status = initial_status.to_sym
        @current_step = current_step&.to_sym
        @pending_inputs = Array(pending_inputs).map { |entry| PendingInput.from(entry) }.freeze
        @pending_actions = Array(pending_actions).map { |entry| PendingAction.from(entry) }.freeze
        @artifacts = Array(artifacts).map { |entry| ArtifactReference.from(entry) }.freeze
        @contracts = Array(contracts).map(&:to_s).freeze
        @services = Array(services).map(&:to_sym).freeze
        @interfaces = Array(interfaces).map(&:to_sym).freeze
        @surfaces = Array(surfaces).map(&:to_sym).freeze
        @exports = Array(exports).map(&:to_sym).freeze
        @imports = Array(imports).map(&:to_sym).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.from(value)
        return value if value.is_a?(self)

        new(**symbolize_keys(value))
      end

      def to_h
        {
          name: name,
          purpose: purpose,
          initial_status: initial_status,
          current_step: current_step,
          pending_inputs: pending_inputs.map(&:to_h),
          pending_actions: pending_actions.map(&:to_h),
          artifacts: artifacts.map(&:to_h),
          contracts: contracts.dup,
          services: services.dup,
          interfaces: interfaces.dup,
          surfaces: surfaces.dup,
          exports: exports.dup,
          imports: imports.dup,
          metadata: metadata.dup
        }
      end

      def self.symbolize_keys(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
      private_class_method :symbolize_keys
    end
  end
end
