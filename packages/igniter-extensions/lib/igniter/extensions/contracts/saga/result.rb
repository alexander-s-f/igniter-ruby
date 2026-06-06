# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        class Result
          attr_reader :execution_result, :error, :failed_node, :compensations

          def initialize(success:, execution_result:, error: nil, failed_node: nil, compensations: [])
            @success = success
            @execution_result = execution_result
            @error = error
            @failed_node = failed_node&.to_sym
            @compensations = compensations.freeze
            freeze
          end

          def success?
            @success
          end

          def failed?
            !success?
          end

          def output(name)
            execution_result.output(name)
          end

          def explain
            Formatter.format(self)
          end

          alias to_s explain

          def to_h
            {
              success: success?,
              failed_node: failed_node,
              error: error&.message,
              compensations: compensations.map do |record|
                {
                  node: record.node_name,
                  success: record.success?,
                  error: record.error&.message
                }
              end,
              execution_result: execution_result.to_h
            }
          end
        end
      end
    end
  end
end
