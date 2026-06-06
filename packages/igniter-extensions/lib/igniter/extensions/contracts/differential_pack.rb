# frozen_string_literal: true

require_relative "differential/divergence"
require_relative "differential/formatter"
require_relative "differential/report"
require_relative "differential/runner"

module Igniter
  module Extensions
    module Contracts
      module DifferentialPack
        module_function

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_differential,
            metadata: { category: :developer }
          )
        end

        def install_into(kernel)
          kernel
        end

        def compare(
          inputs:,
          primary_environment: nil,
          primary_compiled_graph: nil,
          primary_result: nil,
          candidate_environment: nil,
          candidate_compiled_graph: nil,
          candidate_result: nil,
          tolerance: nil,
          primary_name: "primary",
          candidate_name: "candidate"
        )
          Differential::Runner.new(
            primary_name: primary_name,
            candidate_name: candidate_name,
            tolerance: tolerance
          ).compare(
            inputs: inputs,
            primary_environment: primary_environment,
            primary_compiled_graph: primary_compiled_graph,
            primary_result: primary_result,
            candidate_environment: candidate_environment,
            candidate_compiled_graph: candidate_compiled_graph,
            candidate_result: candidate_result
          )
        end

        def shadow(**arguments)
          on_divergence = arguments.delete(:on_divergence)
          report = compare(**arguments)
          on_divergence.call(report) if on_divergence && !report.match?
          report
        end
      end
    end
  end
end
