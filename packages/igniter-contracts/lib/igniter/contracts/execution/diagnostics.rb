# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module Diagnostics
        module_function

        def build_report(result:, profile:)
          report = DiagnosticsReport.new

          profile.diagnostics_contributors.each do |entry|
            contributor = entry.value
            next unless contributor.respond_to?(:augment)

            contributor.augment(report: report, result: result, profile: profile)
          end

          report
        end
      end
    end
  end
end
