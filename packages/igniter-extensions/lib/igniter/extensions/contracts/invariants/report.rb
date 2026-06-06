# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Report
          attr_reader :suite, :outputs, :violations, :execution_result

          def initialize(suite:, outputs:, violations:, execution_result: nil)
            @suite = suite
            @outputs = outputs.transform_keys(&:to_sym).freeze
            @violations = Array(violations).freeze
            @execution_result = execution_result
            freeze
          end

          def valid?
            violations.empty?
          end

          def invalid?
            !valid?
          end

          def summary
            return "valid" if valid?

            "invalid - #{violations.length} invariant(s) violated: #{violations.map(&:name).join(", ")}"
          end

          def to_h
            {
              valid: valid?,
              outputs: outputs,
              invariants: suite.names,
              violations: violations.map(&:to_h),
              execution_result: execution_result&.to_h
            }
          end
        end
      end
    end
  end
end
