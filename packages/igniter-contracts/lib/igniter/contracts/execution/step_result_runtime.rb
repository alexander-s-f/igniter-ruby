# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module StepResultRuntime
        module_function

        def handle_step(operation:, state:, **)
          failed_dependency = failed_step_dependency(operation, state: state)
          return halted_dependency_result(operation, failed_dependency) if failed_dependency

          callable = operation.attributes[:callable]
          normalize_step_result(callable.call(**step_dependency_values(operation, state: state)))
        end

        def failed_step_dependency(operation, state:)
          Array(operation.attributes[:depends_on]).filter_map do |dependency|
            dependency_name = dependency.to_sym
            value = state.fetch(dependency_name)

            { name: dependency_name, result: value } if value.is_a?(StepResult) && value.failure?
          end.first
        end

        def halted_dependency_result(operation, dependency)
          StepResult.failure(
            code: :halted_dependency,
            message: "step #{operation.name} halted because dependency #{dependency.fetch(:name)} failed",
            details: {
              dependency: dependency.fetch(:name),
              failure: dependency.fetch(:result).failure
            }
          )
        end

        def step_dependency_values(operation, state:)
          Array(operation.attributes[:depends_on]).each_with_object({}) do |dependency, memo|
            dependency_name = dependency.to_sym
            value = state.fetch(dependency_name)
            memo[dependency_name] = value.is_a?(StepResult) ? value.value : value
          end
        end

        def normalize_step_result(value)
          value.is_a?(StepResult) ? value : StepResult.success(value)
        end
      end
    end
  end
end
