# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Provenance
        class Builder
          def self.build(output_name, result)
            new(result).build(output_name)
          end

          def initialize(result)
            @result = result
            @compiled_graph = result.compiled_graph
            @operations = @compiled_graph.operations.reject(&:output?).each_with_object({}) do |operation, memo|
              memo[operation.name] = operation
            end
          end

          def build(output_name)
            output_name = output_name.to_sym

            raise Igniter::Contracts::Error, "execution result does not carry a compiled graph" unless @compiled_graph

            unless output_names.include?(output_name)
              raise Igniter::Contracts::Error,
                    "no output named '#{output_name}' in compiled graph"
            end

            source_operation = @operations.fetch(output_name) do
              raise Igniter::Contracts::Error,
                    "source node '#{output_name}' for output '#{output_name}' not found in compiled graph"
            end

            Lineage.new(build_trace(source_operation, {}))
          end

          private

          def output_names
            @output_names ||= @compiled_graph.operations.select(&:output?).map(&:name)
          end

          def build_trace(operation, memo)
            return memo[operation.name] if memo.key?(operation.name)

            memo[operation.name] = nil

            contributing = dependency_names_for(operation).each_with_object({}) do |dependency_name, acc|
              dependency_operation = @operations[dependency_name]
              next unless dependency_operation

              acc[dependency_name] = build_trace(dependency_operation, memo)
            end

            trace = NodeTrace.new(
              name: operation.name,
              kind: operation.kind,
              value: resolved_value_for(operation),
              contributing: contributing
            )

            memo[operation.name] = trace
          end

          def dependency_names_for(operation)
            names = []
            names.concat(Array(operation.attributes[:depends_on])) if operation.attribute?(:depends_on)
            names << operation.attributes[:from] if operation.attribute?(:from)
            names.map(&:to_sym).uniq
          end

          def resolved_value_for(operation)
            @result.state.fetch(operation.name)
          end
        end
      end
    end
  end
end
