# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Audit
        module Builder
          module_function

          def build(target)
            result = unwrap_result(target)
            compiled_graph = result.compiled_graph
            outputs = result.outputs.to_h
            state_values = result.state.to_h

            Snapshot.new(
              graph: graph_name(compiled_graph),
              profile_fingerprint: result.profile_fingerprint,
              events: build_events(compiled_graph, state_values: state_values, outputs: outputs),
              states: build_states(compiled_graph, state_values: state_values, outputs: outputs),
              children: build_children(state_values),
              output_names: compiled_graph.operations.select(&:output?).map(&:name)
            )
          end

          def unwrap_result(target)
            return target.execution_result if target.respond_to?(:execution_result)

            target
          end

          def graph_name(compiled_graph)
            operation_names = compiled_graph.operations.reject(&:output?).map(&:name)
            return "contracts_graph" if operation_names.empty?

            "contracts_graph(#{operation_names.join(",")})"
          end

          def build_events(compiled_graph, state_values:, outputs:)
            compiled_graph.operations.each_with_index.map do |operation, index|
              Event.new(
                event_id: "#{operation.kind}:#{operation.name}:#{index}",
                type: event_type_for(operation),
                node_name: operation.name,
                path: [operation.name],
                status: status_for(operation, state_values: state_values, outputs: outputs),
                payload: payload_for(operation, state_values: state_values, outputs: outputs)
              )
            end
          end

          def build_states(compiled_graph, state_values:, outputs:)
            compiled_graph.operations.each_with_object({}) do |operation, memo|
              next if operation.output?

              value = operation.output? ? outputs[operation.name] : state_values[operation.name]
              memo[operation.name] = {
                path: [operation.name],
                kind: operation.kind,
                status: status_for(operation, state_values: state_values, outputs: outputs),
                value: serialize_value(value),
                dependencies: dependency_names_for(operation)
              }
            end
          end

          def build_children(state_values)
            state_values.each_with_object([]) do |(name, value), memo|
              next unless nested_execution_result?(value)

              memo << {
                node_name: name,
                snapshot: build(value).to_h
              }
            end
          end

          def event_type_for(operation)
            return :output_observed if operation.output?

            :"#{operation.kind}_observed"
          end

          def status_for(operation, state_values:, outputs:)
            collection = operation.output? ? outputs : state_values
            collection.key?(operation.name) ? :succeeded : :missing
          end

          def payload_for(operation, state_values:, outputs:)
            value = operation.output? ? outputs[operation.name] : state_values[operation.name]
            payload = {
              kind: operation.kind,
              value: serialize_value(value)
            }

            dependencies = dependency_names_for(operation)
            payload[:dependencies] = dependencies if dependencies.any?
            payload
          end

          def dependency_names_for(operation)
            names = []
            names.concat(Array(operation.attributes[:depends_on])) if operation.attribute?(:depends_on)
            names << operation.attributes[:from] if operation.attribute?(:from)
            names.map(&:to_sym).uniq
          end

          def serialize_value(value)
            case value
            when Igniter::Contracts::ExecutionResult
              {
                type: :execution_result,
                profile_fingerprint: value.profile_fingerprint,
                outputs: value.outputs.to_h
              }
            when Array
              value.map { |item| serialize_value(item) }
            when Hash
              value.transform_keys(&:to_sym).transform_values { |item| serialize_value(item) }
            else
              value
            end
          end

          def nested_execution_result?(value)
            value.is_a?(Igniter::Contracts::ExecutionResult)
          end
        end
      end
    end
  end
end
