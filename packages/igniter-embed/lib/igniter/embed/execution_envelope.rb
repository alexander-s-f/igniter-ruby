# frozen_string_literal: true

module Igniter
  module Embed
    class ExecutionEnvelope
      attr_reader :name, :inputs, :result, :outputs, :errors, :metadata

      def initialize(name:, inputs:, result: nil, errors: nil, metadata: {})
        @name = name.to_sym
        @inputs = inputs.freeze
        @result = result
        @outputs = result ? result.outputs : Igniter::Contracts::NamedValues.new({})
        @errors = Array(errors).freeze
        @metadata = metadata.freeze
        freeze
      end

      def success?
        result && errors.empty?
      end

      def failure?
        !success?
      end

      def output(name)
        outputs.fetch(name.to_sym)
      end

      def to_h
        {
          name: name,
          inputs: inputs,
          success: success?,
          outputs: outputs.to_h,
          errors: errors.map { |error| normalize_error(error) },
          metadata: metadata
        }
      end

      private

      def normalize_error(error)
        return error.to_h if error.respond_to?(:to_h)

        { class: error.class.name, message: error.message }
      end
    end
  end
end
