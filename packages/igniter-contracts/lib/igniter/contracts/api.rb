# frozen_string_literal: true

module Igniter
  module Contracts
    class << self
      def build_kernel(*packs)
        install_packs(Assembly::Kernel.new.install(BaselinePack), packs)
      end

      def build_profile(*packs)
        build_kernel(*packs).finalize
      end

      def with(*packs)
        Environment.new(profile: build_profile(*packs))
      end

      def default_kernel
        @default_kernel ||= build_kernel
      end

      def default_profile
        @default_profile ||= default_kernel.finalize
      end

      def compile(profile: default_profile, &block)
        Execution::Compiler.compile(profile: profile, &block)
      end

      def validation_report(profile: default_profile, &block)
        Execution::Compiler.validation_report(profile: profile, &block)
      end

      def compilation_report(profile: default_profile, &block)
        Execution::Compiler.compilation_report(profile: profile, &block)
      end

      def execute(compiled_graph, inputs:, profile: default_profile)
        execute_with(:inline, compiled_graph, inputs: inputs, profile: profile)
      end

      def execute_with(executor_name, compiled_graph, inputs:, profile: default_profile, runtime: Execution::Runtime)
        executor = profile.executor(executor_name)
        hook_spec = Assembly::HookSpecs.fetch(:executors)
        invocation = Execution::ExecutionRequest.new(
          compiled_graph: compiled_graph,
          inputs: inputs,
          profile: profile,
          runtime: runtime
        )
        result = executor.call(invocation: invocation)
        hook_spec.validate_result!(executor_name, result)
      rescue KeyError
        raise UnknownExecutorError, "unknown executor #{executor_name}"
      end

      def diagnose(result, profile: default_profile)
        Execution::Diagnostics.build_report(result: result, profile: profile)
      end

      def apply_effect(effect_name, payload:, context: {}, profile: default_profile)
        effect = profile.effect(effect_name)
        invocation = Execution::EffectInvocation.new(
          payload: payload,
          context: context,
          profile: profile
        )
        effect.call(invocation: invocation)
      rescue KeyError
        raise UnknownEffectError, "unknown effect #{effect_name}"
      end

      def reset_defaults!
        @default_kernel = nil
        @default_profile = nil
      end

      private

      def install_packs(kernel, packs)
        normalize_packs(packs).each do |pack|
          kernel.install(pack)
        end
        kernel
      end

      def normalize_packs(packs)
        packs.flatten.compact.uniq
      end
    end
  end
end
