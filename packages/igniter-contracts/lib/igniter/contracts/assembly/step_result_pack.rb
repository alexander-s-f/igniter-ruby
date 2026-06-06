# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module StepResultPack
        module_function

        def manifest
          PackManifest.new(
            name: :step_result,
            node_contracts: [PackManifest.node(:step)],
            registry_contracts: [
              PackManifest.validator(:step_dependencies),
              PackManifest.validator(:step_callables),
              PackManifest.diagnostic(:step_trace)
            ]
          )
        end

        def install_into(kernel)
          kernel.nodes.register(:step, NodeType.new(kind: :step, metadata: { category: :pipeline }))
          kernel.dsl_keywords.register(:step, step_keyword)
          kernel.validators.register(:step_dependencies, Execution::StepResultValidators.method(:validate_step_dependencies))
          kernel.validators.register(:step_callables, Execution::StepResultValidators.method(:validate_step_callables))
          kernel.runtime_handlers.register(:step, Execution::StepResultRuntime.method(:handle_step))
          kernel.diagnostics_contributors.register(:step_trace, Execution::StepResultDiagnostics)
          kernel
        end

        def step_keyword
          DslKeyword.new(:step, lambda { |name, builder:, **attributes, &block|
            normalized_attributes = attributes.dup
            normalized_attributes[:callable] = normalized_attributes.delete(:call) if normalized_attributes.key?(:call)
            normalized_attributes[:callable] = block if block
            builder.add_operation(kind: :step, name: name, **normalized_attributes)
          })
        end
      end
    end
  end
end
