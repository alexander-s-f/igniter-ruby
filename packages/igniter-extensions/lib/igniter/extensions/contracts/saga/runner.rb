# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        class SagaError < Igniter::Contracts::Error; end

        class Runner
          def initialize(compiled_graph:, profile:, compensations:)
            @compiled_graph = compiled_graph
            @profile = profile
            @compensations = normalize_compensations(compensations)
          end

          def run(inputs:)
            state = Igniter::Contracts::MutableNamedValues.new
            outputs = Igniter::Contracts::MutableNamedValues.new
            normalized_inputs = Igniter::Contracts::NamedValues.new(inputs)
            completed_operations = []
            failed_operation = nil

            @compiled_graph.operations.each do |operation|
              failed_operation = operation
              handler = @profile.runtime_handler(operation.kind)
              value = handler.call(
                operation: operation,
                state: state,
                outputs: outputs,
                inputs: normalized_inputs,
                profile: @profile
              )

              state.write(operation.name, value) unless operation.output?
              outputs.write(operation.name, value) if operation.output?
              completed_operations << operation unless operation.output?
            end

            Result.new(
              success: true,
              execution_result: execution_result_for(state, outputs)
            )
          rescue StandardError => e
            execution_result = execution_result_for(state, outputs)

            Result.new(
              success: false,
              execution_result: execution_result,
              error: e,
              failed_node: failed_operation&.name,
              compensations: run_compensations(
                completed_operations.reverse,
                execution_result: execution_result,
                inputs: normalized_inputs
              )
            )
          end

          private

          def normalize_compensations(compensations)
            case compensations
            when CompensationSet
              compensations
            else
              CompensationSet.new.tap do |set|
                compensations.each do |node_name, handler|
                  set.compensate(node_name, &handler)
                end
                set.finalize!
              end
            end
          end

          def execution_result_for(state, outputs)
            Igniter::Contracts::ExecutionResult.new(
              state: state.snapshot,
              outputs: outputs.snapshot,
              profile_fingerprint: @profile.fingerprint,
              compiled_graph: @compiled_graph
            )
          end

          def run_compensations(operations, execution_result:, inputs:)
            operations.filter_map do |operation|
              compensation = @compensations[operation.name]
              next unless compensation

              attempt_compensation(compensation, operation, execution_result: execution_result, inputs: inputs)
            end
          end

          def attempt_compensation(compensation, operation, execution_result:, inputs:)
            compensation.run(
              inputs: compensation_inputs_for(operation, execution_result: execution_result, inputs: inputs),
              value: execution_result.state[operation.name]
            )
            CompensationRecord.new(node_name: compensation.node_name, success: true)
          rescue StandardError => e
            CompensationRecord.new(node_name: compensation.node_name, success: false, error: e)
          end

          def compensation_inputs_for(operation, execution_result:, inputs:)
            dependency_names_for(operation).each_with_object({}) do |dependency_name, memo|
              memo[dependency_name] =
                if execution_result.state.key?(dependency_name)
                  execution_result.state[dependency_name]
                else
                  inputs[dependency_name]
                end
            end
          end

          def dependency_names_for(operation)
            names = []
            names.concat(Array(operation.attributes[:depends_on])) if operation.attribute?(:depends_on)
            names << operation.attributes[:from] if operation.attribute?(:from)
            names.map(&:to_sym).uniq
          end
        end
      end
    end
  end
end
