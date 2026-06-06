# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module StepResultValidators
        module_function

        def validate_step_dependencies(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          available = operations.reject(&:output?).map(&:name)
          missing = step_operations(operations)
                    .flat_map { |operation| Array(operation.attributes[:depends_on]) }
                    .map(&:to_sym)
                    .reject { |name| available.include?(name) }
                    .uniq
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_step_dependencies,
            message: "step dependencies are not defined: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def validate_step_callables(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          missing = step_operations(operations)
                    .reject { |operation| operation.attributes[:callable].respond_to?(:call) }
                    .map(&:name)
          return [] if missing.empty?

          [ValidationFinding.new(
            code: :missing_step_callable,
            message: "step nodes require a callable: #{missing.map(&:to_s).join(", ")}",
            subjects: missing
          )]
        end

        def step_operations(operations)
          operations.select { |operation| operation.kind == :step }
        end
      end
    end
  end
end
