# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class DispatchResult
          attr_reader :status, :events, :errors, :result, :execution_result, :execution_error

          def initialize(status:, events:, errors:, result:, execution_result:, execution_error: nil)
            @status = status.to_sym
            @events = events.freeze
            @errors = errors.freeze
            @result = result
            @execution_result = execution_result
            @execution_error = execution_error
            freeze
          end

          def success?
            status == :succeeded
          end

          def failed?
            status == :failed
          end

          def output(name)
            execution_result&.output(name)
          end

          def to_h
            {
              status: status,
              success: success?,
              events: events.map(&:to_h),
              errors: errors.map do |entry|
                {
                  event: entry.fetch(:event).to_h,
                  subscription: entry.fetch(:subscription).to_h,
                  error: {
                    type: entry.fetch(:error).class.name,
                    message: entry.fetch(:error).message
                  }
                }
              end,
              execution_error: execution_error && {
                type: execution_error.class.name,
                message: execution_error.message
              },
              result: result&.to_h,
              execution_result: execution_result&.to_h
            }
          end
        end
      end
    end
  end
end
