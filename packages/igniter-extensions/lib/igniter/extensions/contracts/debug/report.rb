# frozen_string_literal: true

require_relative "profile_snapshot"

module Igniter
  module Extensions
    module Contracts
      module Debug
        class Report
          attr_reader :profile_snapshot,
                      :compilation_report,
                      :execution_result,
                      :diagnostics_report,
                      :provenance_summary

          def initialize(profile_snapshot:, compilation_report: nil, execution_result: nil, diagnostics_report: nil,
                         provenance_summary: nil)
            @profile_snapshot = profile_snapshot
            @compilation_report = compilation_report
            @execution_result = execution_result
            @diagnostics_report = diagnostics_report
            @provenance_summary = provenance_summary
            freeze
          end

          def ok?
            compilation_report.nil? || compilation_report.ok?
          end

          def invalid?
            !ok?
          end

          def to_h
            payload = {
              profile: profile_snapshot.to_h,
              ok: ok?
            }

            payload[:compilation] = compilation_report.to_h if compilation_report
            payload[:execution] = execution_result.to_h if execution_result
            payload[:diagnostics] = diagnostics_report.to_h if diagnostics_report
            payload[:provenance] = provenance_summary if provenance_summary
            payload
          end
        end
      end
    end
  end
end
