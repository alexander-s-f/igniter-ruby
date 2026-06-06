# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Capabilities
        class Error < StandardError; end

        class CapabilityViolationError < Error
          attr_reader :report

          def initialize(message = nil, report:)
            @report = report
            super(message || default_message)
          end

          def to_h
            {
              message: message,
              report: report.to_h
            }
          end

          private

          def default_message
            return "capability policy violated" if report.violations.empty?

            report.violations.map(&:message).join("; ")
          end
        end
      end
    end
  end
end
