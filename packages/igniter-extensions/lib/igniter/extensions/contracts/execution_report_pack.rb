# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module ExecutionReportPack
        module_function

        REPORT_CONTRIBUTOR = Module.new do
          module_function

          def augment(report:, result:, profile:)
            report.add_section(:execution_report, {
                                 profile_fingerprint: profile.fingerprint,
                                 pack_names: profile.pack_names.sort,
                                 output_count: result.outputs.length,
                                 state_count: result.state.length,
                                 outputs: result.outputs.to_h,
                                 state_keys: result.state.keys.sort
                               })
          end
        end

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_execution_report,
            registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:execution_report)]
          )
        end

        def install_into(kernel)
          kernel.diagnostics_contributors.register(:execution_report, REPORT_CONTRIBUTOR)
          kernel
        end
      end
    end
  end
end
