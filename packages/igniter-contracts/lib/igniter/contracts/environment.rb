# frozen_string_literal: true

module Igniter
  module Contracts
    class Environment
      attr_reader :profile

      def initialize(profile:)
        @profile = profile
      end

      def compile(&block)
        Contracts.compile(profile: profile, &block)
      end

      def validation_report(&block)
        Contracts.validation_report(profile: profile, &block)
      end

      def compilation_report(&block)
        Contracts.compilation_report(profile: profile, &block)
      end

      def execute(compiled_graph, inputs:)
        Contracts.execute(compiled_graph, inputs: inputs, profile: profile)
      end

      def execute_with(executor_name, compiled_graph, inputs:, runtime: Execution::Runtime)
        Contracts.execute_with(
          executor_name,
          compiled_graph,
          inputs: inputs,
          profile: profile,
          runtime: runtime
        )
      end

      def run(inputs:, &block)
        execute(compile(&block), inputs: inputs)
      end

      def diagnose(result)
        Contracts.diagnose(result, profile: profile)
      end

      def apply_effect(effect_name, payload:, context: {})
        Contracts.apply_effect(effect_name, payload: payload, context: context, profile: profile)
      end
    end
  end
end
