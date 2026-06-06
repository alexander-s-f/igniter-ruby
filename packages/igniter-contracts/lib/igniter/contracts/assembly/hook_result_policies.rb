# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module HookResultPolicies
        module_function

        def operations_array(result)
          return "must return an Array of operations" unless result.is_a?(Array)

          result.each_with_index do |operation, index|
            message = validate_operation(operation)
            return "must return an Array of operations; element #{index} #{message}" if message
          end

          nil
        end

        def execution_result(result)
          return "must return an ExecutionResult" unless result.is_a?(Execution::ExecutionResult)

          nil
        end

        def validation_findings(result)
          return nil if result.nil?
          return "must return an Array of ValidationFinding entries" unless result.is_a?(Array)

          invalid_index = result.find_index { |entry| !entry.is_a?(Execution::ValidationFinding) }
          return nil if invalid_index.nil?

          "must return an Array of ValidationFinding entries; element #{invalid_index} is invalid"
        end

        def validate_operation(operation)
          return "must be an Execution::Operation" unless operation.is_a?(Execution::Operation)
          return "must use Symbol kind" unless operation.kind.is_a?(Symbol)
          return "must use Symbol name" unless operation.name.is_a?(Symbol)
          return "must use Hash attributes" unless operation.attributes.is_a?(Hash)

          nil
        end
      end
    end
  end
end
