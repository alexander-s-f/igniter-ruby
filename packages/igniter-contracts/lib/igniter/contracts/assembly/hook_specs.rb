# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module HookSpecs
        module_function

        REGISTRY_SPECS = {
          dsl_keywords: HookSpec.new(
            registry: :dsl_keywords,
            method_name: :call,
            required_keywords: %i[builder],
            role: :dsl_keyword,
            return_policy: :opaque
          ),
          normalizers: HookSpec.new(
            registry: :normalizers,
            method_name: :call,
            required_keywords: %i[operations profile],
            role: :graph_transformer,
            return_policy: :operations_array,
            result_validator: HookResultPolicies.method(:operations_array)
          ),
          validators: HookSpec.new(
            registry: :validators,
            method_name: :call,
            required_keywords: %i[operations profile],
            role: :validator,
            return_policy: :validation_findings,
            result_validator: HookResultPolicies.method(:validation_findings)
          ),
          runtime_handlers: HookSpec.new(
            registry: :runtime_handlers,
            method_name: :call,
            required_keywords: %i[operation state outputs inputs profile],
            role: :runtime_handler,
            return_policy: :value
          ),
          diagnostics_contributors: HookSpec.new(
            registry: :diagnostics_contributors,
            method_name: :augment,
            required_keywords: %i[report result profile],
            role: :diagnostics_contributor,
            return_policy: :ignored
          ),
          effects: HookSpec.new(
            registry: :effects,
            method_name: :call,
            required_keywords: %i[invocation],
            role: :effect_adapter,
            return_policy: :opaque
          ),
          executors: HookSpec.new(
            registry: :executors,
            method_name: :call,
            required_keywords: %i[invocation],
            role: :executor,
            return_policy: :execution_result,
            result_validator: HookResultPolicies.method(:execution_result)
          )
        }.freeze

        def fetch(registry_name)
          REGISTRY_SPECS.fetch(registry_name.to_sym)
        end

        def registry_names
          REGISTRY_SPECS.keys
        end
      end
    end
  end
end
