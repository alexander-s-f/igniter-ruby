# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module BaselineNormalizers
        module_function

        def normalize_operation_attributes(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
          operations.map do |operation|
            attributes = operation.attributes
            normalized_attributes = attributes.dup

            next operation unless normalized_attributes.key?(:depends_on)

            normalized_attributes[:depends_on] = Array(normalized_attributes[:depends_on]).map(&:to_sym)
            operation.with_attributes(normalized_attributes)
          end
        end
      end
    end
  end
end
