# frozen_string_literal: true

require_relative "provenance/node_trace"
require_relative "provenance/text_formatter"
require_relative "provenance/lineage"
require_relative "provenance/builder"

module Igniter
  module Extensions
    module Contracts
      module ProvenancePack
        module_function

        REPORT_CONTRIBUTOR = Module.new do
          module_function

          def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
            summary = result.outputs.keys.sort.each_with_object({}) do |output_name, memo|
              lineage = Igniter::Extensions::Contracts::ProvenancePack.lineage(result, output_name)
              memo[output_name] = {
                value: lineage.value,
                contributing_inputs: lineage.contributing_inputs
              }
            end

            report.add_section(:provenance, { outputs: summary })
          end
        end

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_provenance,
            registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:provenance)]
          )
        end

        def install_into(kernel)
          kernel.diagnostics_contributors.register(:provenance, REPORT_CONTRIBUTOR)
          kernel
        end

        def lineage(result, output_name)
          Provenance::Builder.build(output_name, result)
        end

        def explain(result, output_name)
          lineage(result, output_name).explain
        end
      end
    end
  end
end
