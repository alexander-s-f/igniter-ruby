# frozen_string_literal: true

require_relative "debug/profile_snapshot"
require_relative "debug/pack_audit"
require_relative "debug/report"

module Igniter
  module Extensions
    module Contracts
      module DebugPack
        module_function

        REPORT_CONTRIBUTOR = Module.new do
          module_function

          def augment(report:, result:, profile:)
            snapshot = DebugPack.profile_snapshot(profile)
            report.add_section(:debug, {
                                 profile_fingerprint: profile.fingerprint,
                                 pack_names: snapshot.pack_names,
                                 registry_keys: snapshot.registry_keys,
                                 output_names: result.outputs.keys.sort,
                                 state_keys: result.state.keys.sort,
                                 operation_count: result.compiled_graph.operations.length
                               })
          end
        end

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_debug,
            requires_packs: [ExecutionReportPack, ProvenancePack],
            registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:debug)],
            metadata: { category: :developer }
          )
        end

        def install_into(kernel)
          kernel.diagnostics_contributors.register(:debug, REPORT_CONTRIBUTOR)
          kernel
        end

        def profile_snapshot(profile)
          Debug::ProfileSnapshot.new(profile: profile)
        end

        def pack_snapshot(pack_or_name, profile:)
          manifest =
            case pack_or_name
            when Symbol, String
              profile.pack_manifest(pack_or_name)
            else
              pack_or_name.respond_to?(:manifest) ? pack_or_name.manifest : profile.pack_manifest(pack_or_name)
            end
          raise ArgumentError, "unknown pack #{pack_or_name}" unless manifest

          Debug::PackSnapshot.new(manifest)
        end

        def audit(pack, profile: nil)
          Debug::PackAudit.build(pack, profile: profile)
        end

        def snapshot(result, profile:)
          diagnostics = Igniter::Contracts.diagnose(result, profile: profile)
          Debug::Report.new(
            profile_snapshot: profile_snapshot(profile),
            execution_result: result,
            diagnostics_report: diagnostics,
            provenance_summary: provenance_summary(result)
          )
        end

        def report(environment, inputs: nil, compiled_graph: nil, &block)
          compilation =
            if block
              environment.compilation_report(&block)
            elsif compiled_graph
              nil
            else
              raise ArgumentError, "debug_report requires a block or compiled_graph"
            end

          graph = compiled_graph || compilation&.compiled_graph
          if inputs.nil? || compilation&.invalid?
            return Debug::Report.new(profile_snapshot: profile_snapshot(environment.profile),
                                     compilation_report: compilation)
          end

          result = environment.execute(graph, inputs: inputs)
          diagnostics = environment.diagnose(result)

          Debug::Report.new(
            profile_snapshot: profile_snapshot(environment.profile),
            compilation_report: compilation,
            execution_result: result,
            diagnostics_report: diagnostics,
            provenance_summary: provenance_summary(result)
          )
        end

        def provenance_summary(result)
          result.outputs.keys.sort.each_with_object({}) do |output_name, memo|
            lineage = ProvenancePack.lineage(result, output_name)
            memo[output_name] = {
              value: lineage.value,
              contributing_inputs: lineage.contributing_inputs,
              trace: lineage.to_h
            }
          end
        end
      end
    end
  end
end
