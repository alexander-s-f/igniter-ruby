# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Error < StandardError; end

        class InvariantError < Error
          attr_reader :violations

          def initialize(message = nil, violations: [])
            @violations = Array(violations).freeze
            super(message || default_message)
          end

          def to_h
            {
              message: message,
              violations: violations.map(&:to_h)
            }
          end

          private

          def default_message
            names = violations.map { |violation| ":#{violation.name}" }.join(", ")
            "#{violations.length} invariant(s) violated: #{names}"
          end
        end
      end
    end
  end
end
