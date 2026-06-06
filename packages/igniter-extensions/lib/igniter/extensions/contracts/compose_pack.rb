# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module ComposePack
        Invocation = Struct.new(:operation, :compiled_graph, :inputs, :profile, keyword_init: true) do
          def initialize(operation:, compiled_graph:, inputs:, profile:)
            super(
              operation: operation,
              compiled_graph: compiled_graph,
              inputs: inputs,
              profile: profile
            )
          end
        end

        module LocalInvoker
          module_function

          def call(invocation:)
            Igniter::Contracts.execute(
              invocation.compiled_graph,
              inputs: invocation.inputs,
              profile: invocation.profile
            )
          end
        end

        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_compose,
              node_contracts: [Igniter::Contracts::PackManifest.node(:compose)],
              registry_contracts: [
                Igniter::Contracts::PackManifest.validator(:compose_dependencies),
                Igniter::Contracts::PackManifest.validator(:compose_contracts),
                Igniter::Contracts::PackManifest.validator(:compose_invokers)
              ],
              metadata: { category: :orchestration },
              provides_capabilities: %i[subgraph_invocation nested_contracts]
            )
          end

          def install_into(kernel)
            kernel.nodes.register(:compose,
                                  Igniter::Contracts::NodeType.new(kind: :compose,
                                                                   metadata: { category: :orchestration }))
            kernel.dsl_keywords.register(:compose, compose_keyword)
            kernel.validators.register(:compose_dependencies, method(:validate_compose_dependencies))
            kernel.validators.register(:compose_contracts, method(:validate_compose_contracts))
            kernel.validators.register(:compose_invokers, method(:validate_compose_invokers))
            kernel.runtime_handlers.register(:compose, method(:handle_compose))
            kernel
          end

          def compose_keyword
            Igniter::Contracts::DslKeyword.new(:compose) do |name, builder:, contract: nil, inputs: {}, output: nil, via: nil, &block|
              compiled_graph = compile_contract(name: name, contract: contract, profile: builder.profile, block: block)
              input_map = normalize_inputs(inputs)

              builder.add_operation(
                kind: :compose,
                name: name,
                depends_on: extract_dependencies(input_map),
                inputs: input_map,
                compiled_graph: compiled_graph,
                output_name: output&.to_sym,
                invoker: via
              )
            end
          end

          def validate_compose_dependencies(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
            available = operations.reject(&:output?).map(&:name)
            missing = operations.select { |operation| operation.kind == :compose }
                                .flat_map { |operation| Array(operation.attributes[:depends_on]) }
                                .map(&:to_sym)
                                .reject { |name| available.include?(name) }
                                .uniq
            return [] if missing.empty?

            [Igniter::Contracts::ValidationFinding.new(
              code: :missing_compose_dependencies,
              message: "compose dependencies are not defined: #{missing.map(&:to_s).join(", ")}",
              subjects: missing
            )]
          end

          def validate_compose_contracts(operations:, profile:)
            compose_operations = operations.select { |operation| operation.kind == :compose }
            findings = []

            invalid_contracts = compose_operations.reject do |operation|
              operation.attributes[:compiled_graph].is_a?(Igniter::Contracts::CompiledGraph)
            end
            if invalid_contracts.any?
              findings << Igniter::Contracts::ValidationFinding.new(
                code: :invalid_compose_contract,
                message: "compose nodes require a compiled contract graph: #{invalid_contracts.map(&:name).join(", ")}",
                subjects: invalid_contracts.map(&:name)
              )
            end

            mismatched = compose_operations.select do |operation|
              compiled_graph = operation.attributes[:compiled_graph]
              compiled_graph.is_a?(Igniter::Contracts::CompiledGraph) &&
                compiled_graph.profile_fingerprint != profile.fingerprint
            end
            if mismatched.any?
              findings << Igniter::Contracts::ValidationFinding.new(
                code: :compose_profile_mismatch,
                message: "compose contracts were compiled against a different profile: #{mismatched.map(&:name).join(", ")}",
                subjects: mismatched.map(&:name)
              )
            end

            missing_outputs = compose_operations.filter_map do |operation|
              output_name = operation.attributes[:output_name]
              next if output_name.nil?

              compiled_graph = operation.attributes[:compiled_graph]
              next if compiled_graph.is_a?(Igniter::Contracts::CompiledGraph) && compose_output_names(compiled_graph).include?(output_name)

              operation.name
            end
            if missing_outputs.any?
              findings << Igniter::Contracts::ValidationFinding.new(
                code: :unknown_compose_output,
                message: "compose output selections are not defined in the nested contract: #{missing_outputs.map(&:to_s).join(", ")}",
                subjects: missing_outputs
              )
            end

            findings
          end

          def validate_compose_invokers(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
            invalid = operations.select { |operation| operation.kind == :compose }
                                .reject do |operation|
              invoker = operation.attributes[:invoker]
              invoker.nil? || invoker.respond_to?(:call)
            end
            return [] if invalid.empty?

            [Igniter::Contracts::ValidationFinding.new(
              code: :invalid_compose_invoker,
              message: "compose via: must be callable: #{invalid.map(&:name).join(", ")}",
              subjects: invalid.map(&:name)
            )]
          end

          def handle_compose(operation:, state:, profile:, **)
            nested_inputs = resolve_inputs(operation, state: state)
            invocation = Invocation.new(
              operation: operation,
              compiled_graph: operation.attributes.fetch(:compiled_graph),
              inputs: nested_inputs,
              profile: profile
            )
            invoker = operation.attributes[:invoker] || LocalInvoker
            result = invoker.call(invocation: invocation)
            unless result.is_a?(Igniter::Contracts::ExecutionResult)
              raise Igniter::Contracts::Error,
                    "compose invoker for #{operation.name} must return an ExecutionResult"
            end

            output_name = operation.attributes[:output_name]
            return result if output_name.nil?

            result.output(output_name)
          end

          private

          def compile_contract(name:, contract:, profile:, block:)
            raise ArgumentError, "compose :#{name} accepts either contract: or a block, not both" if contract && block

            source = contract || block
            raise ArgumentError, "compose :#{name} requires contract: or a block" unless source

            return source if source.is_a?(Igniter::Contracts::CompiledGraph)
            return Igniter::Contracts.compile(profile: profile, &source) if source.respond_to?(:call)

            raise ArgumentError, "compose :#{name} contract must be a compiled graph or callable"
          end

          def normalize_inputs(inputs)
            raise ArgumentError, "compose inputs: must be a Hash" unless inputs.is_a?(Hash)

            inputs.each_with_object({}) do |(key, value), memo|
              memo[key.to_sym] = value
            end.freeze
          end

          def extract_dependencies(input_map)
            input_map.values.grep(Symbol).map(&:to_sym).uniq
          end

          def resolve_inputs(operation, state:)
            operation.attributes.fetch(:inputs).each_with_object({}) do |(key, source), memo|
              memo[key.to_sym] = source.is_a?(Symbol) ? state.fetch(source.to_sym) : source
            end
          end

          def compose_output_names(compiled_graph)
            compiled_graph.operations.select(&:output?).map(&:name)
          end
        end
      end
    end
  end
end
