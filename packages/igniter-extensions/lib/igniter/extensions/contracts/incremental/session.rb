# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Incremental
        class Session
          attr_reader :compiled_graph, :profile

          def initialize(compiled_graph:, profile:)
            @compiled_graph = compiled_graph
            @profile = profile
            @node_states = {}
            @last_result = nil
          end

          def run(inputs:)
            normalized_inputs = Igniter::Contracts::NamedValues.new(inputs)
            current_values = Igniter::Contracts::MutableNamedValues.new
            current_outputs = Igniter::Contracts::MutableNamedValues.new
            current_states = {}

            changed_nodes = []
            skipped_nodes = []
            backdated_nodes = []
            recomputed_count = 0

            compiled_graph.operations.each do |operation|
              if operation.output?
                current_outputs.write(operation.name, current_values.fetch(operation.name))
                next
              end

              if operation.kind == :input
                state = resolve_input_state(operation, normalized_inputs)
                current_states[operation.name] = state
                current_values.write(operation.name, state.value)
                changed_nodes << operation.name if changed_value?(operation.name, state.value)
                next
              end

              dependency_versions = dependency_names_for(operation).each_with_object({}) do |dependency_name, memo|
                if current_states.key?(dependency_name)
                  memo[dependency_name] =
                    current_states.fetch(dependency_name).value_version
                end
              end

              previous = @node_states[operation.name]

              if previous && previous.dep_snapshot == dependency_versions
                current_states[operation.name] = previous
                current_values.write(operation.name, previous.value)
                skipped_nodes << operation.name
                next
              end

              handler = profile.runtime_handler(operation.kind)
              value = handler.call(
                operation: operation,
                state: current_values,
                outputs: current_outputs,
                inputs: normalized_inputs,
                profile: profile
              )

              value_version =
                if previous && previous.value == value
                  backdated_nodes << operation.name
                  previous.value_version
                else
                  changed_nodes << operation.name if changed_value?(operation.name, value)
                  previous ? previous.value_version + 1 : 1
                end

              current_states[operation.name] = NodeState.new(
                name: operation.name,
                value: value,
                value_version: value_version,
                dep_snapshot: dependency_versions
              )
              current_values.write(operation.name, value)
              recomputed_count += 1
            end

            execution_result = Igniter::Contracts::ExecutionResult.new(
              state: current_values.snapshot,
              outputs: current_outputs.snapshot,
              profile_fingerprint: profile.fingerprint,
              compiled_graph: compiled_graph
            )

            result = Result.new(
              execution_result: execution_result,
              changed_nodes: changed_nodes.uniq,
              skipped_nodes: skipped_nodes.uniq,
              backdated_nodes: backdated_nodes.uniq,
              changed_outputs: changed_outputs_for(execution_result),
              recomputed_count: recomputed_count
            )

            @node_states = current_states.freeze
            @last_result = result
          end

          private

          def resolve_input_state(operation, normalized_inputs)
            value = normalized_inputs.fetch(operation.name)
            previous = @node_states[operation.name]
            value_version = previous && previous.value == value ? previous.value_version : (previous&.value_version || 0) + 1

            NodeState.new(
              name: operation.name,
              value: value,
              value_version: value_version
            )
          end

          def dependency_names_for(operation)
            names = []
            names.concat(Array(operation.attributes[:depends_on])) if operation.attribute?(:depends_on)
            names << operation.attributes[:from] if operation.attribute?(:from)
            names.map(&:to_sym).uniq
          end

          def changed_outputs_for(execution_result)
            previous_outputs = @last_result&.execution_result&.outputs
            execution_result.outputs.keys.each_with_object({}) do |name, memo|
              previous = previous_outputs&.[](name)
              current = execution_result.outputs[name]
              next if previous == current

              memo[name] = { from: previous, to: current }
            end
          end

          def changed_value?(name, value)
            previous = @node_states[name]
            previous.nil? || previous.value != value
          end
        end
      end
    end
  end
end
