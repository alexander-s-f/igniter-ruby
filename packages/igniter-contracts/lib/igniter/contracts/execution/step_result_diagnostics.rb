# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module StepResultDiagnostics
        module_function

        def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
          report.add_section(:step_trace, step_trace(result))
        end

        def step_trace(result)
          result.compiled_graph.operations.filter_map do |operation|
            next unless operation.kind == :step

            step_result = result.state[operation.name]
            next unless step_result.is_a?(StepResult)

            trace_entry(operation, step_result)
          end
        end

        def trace_entry(operation, step_result)
          {
            name: operation.name,
            status: step_result.success? ? :success : :failed,
            dependencies: Array(operation.attributes[:depends_on]).map(&:to_sym),
            failure: StructuredDump.dump(step_result.failure)
          }
        end
      end
    end
  end
end
