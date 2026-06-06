# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Differential
        class Runner
          def initialize(primary_name:, candidate_name:, tolerance: nil)
            @primary_name = primary_name
            @candidate_name = candidate_name
            @tolerance = tolerance
          end

          def compare(
            inputs:,
            primary_environment: nil,
            primary_compiled_graph: nil,
            primary_result: nil,
            candidate_environment: nil,
            candidate_compiled_graph: nil,
            candidate_result: nil
          )
            primary_result, primary_error = resolve_execution(
              result: primary_result,
              environment: primary_environment,
              compiled_graph: primary_compiled_graph,
              inputs: inputs,
              label: @primary_name
            )
            candidate_result, candidate_error = resolve_execution(
              result: candidate_result,
              environment: candidate_environment,
              compiled_graph: candidate_compiled_graph,
              inputs: inputs,
              label: @candidate_name
            )

            primary_outputs = primary_result ? primary_result.outputs.to_h : {}
            candidate_outputs = candidate_result ? candidate_result.outputs.to_h : {}

            build_report(
              inputs: inputs,
              primary_outputs: primary_outputs,
              candidate_outputs: candidate_outputs,
              primary_error: primary_error,
              candidate_error: candidate_error
            )
          end

          private

          def resolve_execution(result:, environment:, compiled_graph:, inputs:, label:)
            return [result, nil] if result

            if environment.nil? || compiled_graph.nil?
              raise ArgumentError,
                    "#{label} comparison requires either an execution result or environment + compiled_graph"
            end

            begin
              [environment.execute(compiled_graph, inputs: inputs), nil]
            rescue StandardError => e
              [nil, serialize_error(e)]
            end
          end

          def build_report(inputs:, primary_outputs:, candidate_outputs:, primary_error:, candidate_error:)
            common = primary_outputs.keys & candidate_outputs.keys
            divergences = compare_common(primary_outputs, candidate_outputs, common)

            Report.new(
              primary_name: @primary_name,
              candidate_name: @candidate_name,
              inputs: inputs,
              primary_outputs: primary_outputs,
              candidate_outputs: candidate_outputs,
              divergences: divergences,
              primary_only: slice_missing(primary_outputs, candidate_outputs),
              candidate_only: slice_missing(candidate_outputs, primary_outputs),
              primary_error: primary_error,
              candidate_error: candidate_error
            )
          end

          def compare_common(primary_outputs, candidate_outputs, names)
            names.filter_map do |name|
              primary_value = primary_outputs.fetch(name)
              candidate_value = candidate_outputs.fetch(name)
              next if values_match?(primary_value, candidate_value)

              Divergence.new(
                output_name: name,
                primary_value: primary_value,
                candidate_value: candidate_value,
                kind: divergence_kind(primary_value, candidate_value)
              )
            end
          end

          def slice_missing(source, other)
            (source.keys - other.keys).each_with_object({}) do |name, memo|
              memo[name] = source.fetch(name)
            end
          end

          def values_match?(left, right)
            return true if left == right
            return false unless @tolerance
            return false unless left.is_a?(Numeric) && right.is_a?(Numeric)

            (left - right).abs <= @tolerance
          end

          def divergence_kind(left, right)
            left.instance_of?(right.class) ? :value_mismatch : :type_mismatch
          end

          def serialize_error(error)
            payload =
              if error.respond_to?(:to_h)
                error.to_h
              else
                {}
              end

            {
              type: error.class.name,
              message: error.message,
              details: payload
            }
          end
        end
      end
    end
  end
end
