# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module CollectionPack
        INTERNAL_SOURCE = :__collection_items__

        Invocation = Struct.new(:operation, :items, :inputs, :compiled_graph, :profile, :key_name, :window,
                                keyword_init: true) do
          def initialize(operation:, items:, inputs:, compiled_graph:, profile:, key_name:, window:)
            super(
              operation: operation,
              items: Array(items),
              inputs: inputs.transform_keys(&:to_sym).freeze,
              compiled_graph: compiled_graph,
              profile: profile,
              key_name: key_name.to_sym,
              window: window
            )
          end
        end

        module LocalInvoker
          module_function

          def call(invocation:)
            environment = Igniter::Contracts::Environment.new(profile: invocation.profile)
            session = Igniter::Extensions::Contracts::DataflowPack.session(
              environment,
              source: INTERNAL_SOURCE,
              key: invocation.key_name,
              context: invocation.inputs.keys,
              window: invocation.window,
              compiled_graph: invocation.compiled_graph
            )

            result = session.run(inputs: invocation.inputs.merge(INTERNAL_SOURCE => invocation.items))
            result.processed
          end
        end

        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_collection,
              node_contracts: [Igniter::Contracts::PackManifest.node(:collection)],
              registry_contracts: [
                Igniter::Contracts::PackManifest.validator(:collection_dependencies),
                Igniter::Contracts::PackManifest.validator(:collection_contracts),
                Igniter::Contracts::PackManifest.validator(:collection_invokers)
              ],
              requires_packs: [DataflowPack, IncrementalPack],
              metadata: { category: :orchestration },
              provides_capabilities: %i[collection keyed_sessions incremental_collection]
            )
          end

          def install_into(kernel)
            kernel.nodes.register(:collection,
                                  Igniter::Contracts::NodeType.new(kind: :collection,
                                                                   metadata: { category: :orchestration }))
            kernel.dsl_keywords.register(:collection, collection_keyword)
            kernel.validators.register(:collection_dependencies, method(:validate_collection_dependencies))
            kernel.validators.register(:collection_contracts, method(:validate_collection_contracts))
            kernel.validators.register(:collection_invokers, method(:validate_collection_invokers))
            kernel.runtime_handlers.register(:collection, method(:handle_collection))
            kernel
          end

          def collection_keyword
            Igniter::Contracts::DslKeyword.new(:collection) do |name, from:, key:, builder:, inputs: {}, window: nil, contract: nil, via: nil, &block|
              compiled_graph = compile_contract(name: name, contract: contract, profile: builder.profile, block: block)
              input_map = normalize_inputs(inputs)
              source_name = from.to_sym

              builder.add_operation(
                kind: :collection,
                name: name,
                from: source_name,
                key_name: key.to_sym,
                depends_on: [source_name, *extract_dependencies(input_map)].uniq,
                inputs: input_map,
                window: window,
                compiled_graph: compiled_graph,
                invoker: via
              )
            end
          end

          def validate_collection_dependencies(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
            available = operations.reject(&:output?).map(&:name)
            missing = operations.select { |operation| operation.kind == :collection }
                                .flat_map { |operation| Array(operation.attributes[:depends_on]) }
                                .map(&:to_sym)
                                .reject { |name| available.include?(name) }
                                .uniq
            return [] if missing.empty?

            [Igniter::Contracts::ValidationFinding.new(
              code: :missing_collection_dependencies,
              message: "collection dependencies are not defined: #{missing.map(&:to_s).join(", ")}",
              subjects: missing
            )]
          end

          def validate_collection_contracts(operations:, profile:)
            collection_operations = operations.select { |operation| operation.kind == :collection }
            findings = []

            invalid_contracts = collection_operations.reject do |operation|
              operation.attributes[:compiled_graph].is_a?(Igniter::Contracts::CompiledGraph)
            end
            if invalid_contracts.any?
              findings << Igniter::Contracts::ValidationFinding.new(
                code: :invalid_collection_contract,
                message: "collection nodes require a compiled item graph: #{invalid_contracts.map(&:name).join(", ")}",
                subjects: invalid_contracts.map(&:name)
              )
            end

            mismatched = collection_operations.select do |operation|
              compiled_graph = operation.attributes[:compiled_graph]
              compiled_graph.is_a?(Igniter::Contracts::CompiledGraph) &&
                compiled_graph.profile_fingerprint != profile.fingerprint
            end
            if mismatched.any?
              findings << Igniter::Contracts::ValidationFinding.new(
                code: :collection_profile_mismatch,
                message: "collection item graphs were compiled against a different profile: #{mismatched.map(&:name).join(", ")}",
                subjects: mismatched.map(&:name)
              )
            end

            findings
          end

          def validate_collection_invokers(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
            invalid = operations.select { |operation| operation.kind == :collection }
                                .reject do |operation|
              invoker = operation.attributes[:invoker]
              invoker.nil? || invoker.respond_to?(:call)
            end
            return [] if invalid.empty?

            [Igniter::Contracts::ValidationFinding.new(
              code: :invalid_collection_invoker,
              message: "collection via: must be callable: #{invalid.map(&:name).join(", ")}",
              subjects: invalid.map(&:name)
            )]
          end

          def handle_collection(operation:, state:, profile:, **)
            items = state.fetch(operation.attributes.fetch(:from))
            invocation = Invocation.new(
              operation: operation,
              items: items,
              inputs: resolve_inputs(operation, state: state),
              compiled_graph: operation.attributes.fetch(:compiled_graph),
              profile: profile,
              key_name: operation.attributes.fetch(:key_name),
              window: operation.attributes[:window]
            )
            invoker = operation.attributes[:invoker] || LocalInvoker
            result = invoker.call(invocation: invocation)
            unless result.is_a?(Igniter::Extensions::Contracts::Dataflow::CollectionResult)
              raise Igniter::Contracts::Error,
                    "collection invoker for #{operation.name} must return a CollectionResult"
            end

            result
          end

          private

          def compile_contract(name:, contract:, profile:, block:)
            if contract && block
              raise ArgumentError,
                    "collection :#{name} accepts either contract: or a block, not both"
            end

            source = contract || block
            raise ArgumentError, "collection :#{name} requires contract: or a block" unless source

            return source if source.is_a?(Igniter::Contracts::CompiledGraph)
            return Igniter::Contracts.compile(profile: profile, &source) if source.respond_to?(:call)

            raise ArgumentError, "collection :#{name} contract must be a compiled graph or callable"
          end

          def normalize_inputs(inputs)
            raise ArgumentError, "collection inputs: must be a Hash" unless inputs.is_a?(Hash)

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
        end
      end
    end
  end
end
