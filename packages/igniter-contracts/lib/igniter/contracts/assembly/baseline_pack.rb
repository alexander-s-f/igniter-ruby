# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module BaselinePack
        module_function

        def manifest
          PackManifest.new(
            name: :baseline,
            node_contracts: BASELINE_NODE_KINDS.keys.map { |kind| PackManifest.node(kind) },
            registry_contracts: [
              PackManifest.normalizer(:normalize_operation_attributes),
              PackManifest.validator(:uniqueness),
              PackManifest.validator(:outputs),
              PackManifest.validator(:dependencies),
              PackManifest.validator(:callables),
              PackManifest.validator(:effect_dependencies),
              PackManifest.validator(:effect_payload_builders),
              PackManifest.validator(:effect_adapters),
              PackManifest.validator(:types),
              PackManifest.executor(:inline),
              PackManifest.diagnostic(:baseline_summary)
            ]
          )
        end

        BASELINE_NODE_KINDS = {
          input: NodeType.new(kind: :input, metadata: { category: :data }),
          const: NodeType.new(kind: :const, metadata: { category: :value }),
          compute: NodeType.new(kind: :compute, metadata: { category: :data }),
          effect: NodeType.new(kind: :effect, metadata: { category: :effect }),
          output: NodeType.new(kind: :output, metadata: { category: :terminal })
        }.freeze

        BASELINE_DSL_KEYWORDS = {
          input: DslKeyword.new(:input, lambda { |name, builder:, **attributes|
            builder.add_operation(kind: :input, name: name, **attributes)
          }),
          const: DslKeyword.new(:const, lambda { |name, value, builder:|
            builder.add_operation(kind: :const, name: name, value: value)
          }),
          compute: DslKeyword.new(:compute, lambda { |name, builder:, **attributes, &block|
            normalized_attributes = attributes.dup
            normalized_attributes[:callable] = normalized_attributes.delete(:call) if normalized_attributes.key?(:call)
            if normalized_attributes.key?(:using)
              target = normalized_attributes.delete(:using)
              output_name = normalized_attributes.delete(:output)&.to_sym
              normalized_attributes[:callable] = lambda do |**values|
                payload = Contractable.invoke(target, **values).to_h
                output_name && payload.fetch(:success) ? payload.fetch(:outputs).fetch(output_name) : payload
              end
            end
            normalized_attributes[:callable] = block if block
            builder.add_operation(kind: :compute, name: name, **normalized_attributes)
          }),
          effect: DslKeyword.new(:effect, lambda { |name, using:, builder:, callable: nil, **attributes, &block|
            normalized_attributes = attributes.dup
            normalized_attributes[:using] = using.to_sym
            normalized_attributes[:callable] = block if block
            normalized_attributes[:callable] = callable if callable && !block
            builder.add_operation(kind: :effect, name: name, **normalized_attributes)
          }),
          output: DslKeyword.new(:output, lambda { |name, builder:, **attributes|
            builder.add_operation(kind: :output, name: name, **attributes)
          })
        }.freeze

        BASELINE_DIAGNOSTICS = {
          baseline_summary: Module.new do
            module_function

            def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
              report.add_section(:baseline_summary, {
                                   outputs: result.outputs.keys.sort,
                                   state: result.state.keys.sort
                                 })
            end
          end
        }.freeze

        def install_into(kernel)
          install_nodes(kernel)
          install_dsl_keywords(kernel)
          install_normalizers(kernel)
          install_validators(kernel)
          install_runtime_handlers(kernel)
          install_executors(kernel)
          install_diagnostics(kernel)
          kernel
        end

        def install_nodes(kernel)
          BASELINE_NODE_KINDS.each do |key, value|
            kernel.nodes.register(key, value)
          end
        end

        def install_dsl_keywords(kernel)
          BASELINE_DSL_KEYWORDS.each do |key, value|
            kernel.dsl_keywords.register(key, value)
          end
        end

        def install_normalizers(kernel)
          kernel.normalizers.register(:normalize_operation_attributes, Execution::BaselineNormalizers.method(:normalize_operation_attributes))
        end

        def install_validators(kernel)
          kernel.validators.register(:uniqueness, Execution::BaselineValidators.method(:validate_uniqueness))
          kernel.validators.register(:outputs, Execution::BaselineValidators.method(:validate_outputs))
          kernel.validators.register(:dependencies, Execution::BaselineValidators.method(:validate_dependencies))
          kernel.validators.register(:callables, Execution::BaselineValidators.method(:validate_callables))
          kernel.validators.register(:effect_dependencies, Execution::BaselineValidators.method(:validate_effect_dependencies))
          kernel.validators.register(:effect_payload_builders, Execution::BaselineValidators.method(:validate_effect_payload_builders))
          kernel.validators.register(:effect_adapters, Execution::BaselineValidators.method(:validate_effect_adapters))
          kernel.validators.register(:types, Execution::BaselineValidators.method(:validate_types))
        end

        def install_runtime_handlers(kernel)
          kernel.runtime_handlers.register(:input, Execution::BaselineRuntime.method(:handle_input))
          kernel.runtime_handlers.register(:const, Execution::ConstRuntime.method(:handle_const))
          kernel.runtime_handlers.register(:compute, Execution::BaselineRuntime.method(:handle_compute))
          kernel.runtime_handlers.register(:effect, Execution::BaselineRuntime.method(:handle_effect))
          kernel.runtime_handlers.register(:output, Execution::BaselineRuntime.method(:handle_output))
        end

        def install_executors(kernel)
          kernel.executors.register(:inline, Execution::InlineExecutor.method(:call))
        end

        def install_diagnostics(kernel)
          BASELINE_DIAGNOSTICS.each do |key, value|
            kernel.diagnostics_contributors.register(key, value)
          end
        end
      end
    end
  end
end
