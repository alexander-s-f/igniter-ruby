# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class CompilationReport
        attr_reader :operations, :validation_report, :compiled_graph, :profile_fingerprint

        def initialize(operations:, validation_report:, compiled_graph:, profile_fingerprint:)
          @operations = operations.freeze
          @validation_report = validation_report
          @compiled_graph = compiled_graph
          @profile_fingerprint = profile_fingerprint
          freeze
        end

        def ok?
          validation_report.ok?
        end

        def invalid?
          validation_report.invalid?
        end

        def findings
          validation_report.findings
        end

        def to_compiled_graph
          validation_report.raise_if_invalid!
          compiled_graph
        end

        def to_h
          {
            operations: StructuredDump.dump(operations),
            validation_report: validation_report.to_h,
            compiled_graph: StructuredDump.dump(compiled_graph),
            profile_fingerprint: profile_fingerprint,
            ok: ok?
          }
        end
      end
    end
  end
end
