# frozen_string_literal: true

require_relative "invariants/error"
require_relative "invariants/invariant"
require_relative "invariants/violation"
require_relative "invariants/suite"
require_relative "invariants/builder"
require_relative "invariants/report"
require_relative "invariants/cases_report"

module Igniter
  module Extensions
    module Contracts
      module InvariantsPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_invariants,
            metadata: { category: :validation }
          )
        end

        def install_into(kernel)
          kernel
        end

        def build(&block)
          Invariants::Builder.build(&block)
        end

        def check(target, invariants:)
          execution_result = unwrap_execution_result(target)
          outputs = execution_result.outputs.to_h
          violations = invariants.invariants.filter_map { |invariant| invariant.check(outputs) }

          Invariants::Report.new(
            suite: invariants,
            outputs: outputs,
            violations: violations,
            execution_result: execution_result
          )
        end

        def validate!(target, invariants:)
          report = check(target, invariants: invariants)
          raise Invariants::InvariantError.new(nil, violations: report.violations) if report.invalid?

          report
        end

        def run(environment, inputs:, invariants:, compiled_graph: nil, &block)
          graph =
            if block
              environment.compile(&block)
            else
              compiled_graph || raise(ArgumentError, "invariant run requires a block or compiled_graph")
            end

          result = environment.execute(graph, inputs: inputs)
          check(result, invariants: invariants)
        end

        def verify_cases(environment, cases:, invariants:, compiled_graph: nil, &block)
          graph =
            if block
              environment.compile(&block)
            else
              compiled_graph || raise(ArgumentError, "verify_cases requires a block or compiled_graph")
            end

          reports = Array(cases).map do |inputs|
            result = environment.execute(graph, inputs: inputs)
            check(result, invariants: invariants)
          end

          Invariants::CasesReport.new(reports: reports)
        end

        def unwrap_execution_result(target)
          return target.execution_result if target.respond_to?(:execution_result)

          target
        end
      end
    end
  end
end
