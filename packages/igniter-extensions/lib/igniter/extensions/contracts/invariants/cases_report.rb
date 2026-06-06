# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class CasesReport
          attr_reader :reports

          def initialize(reports:)
            @reports = reports.freeze
            freeze
          end

          def valid?
            reports.all?(&:valid?)
          end

          def invalid_cases
            reports.each_with_index.filter_map do |report, index|
              next if report.valid?

              {
                index: index,
                report: report.to_h
              }
            end
          end

          def summary
            return "all cases valid" if valid?

            "#{invalid_cases.length} invalid case(s)"
          end

          def to_h
            {
              valid: valid?,
              case_count: reports.length,
              invalid_cases: invalid_cases
            }
          end
        end
      end
    end
  end
end
