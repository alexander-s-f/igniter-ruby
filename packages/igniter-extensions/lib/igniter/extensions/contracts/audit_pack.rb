# frozen_string_literal: true

require_relative "audit/event"
require_relative "audit/snapshot"
require_relative "audit/builder"

module Igniter
  module Extensions
    module Contracts
      module AuditPack
        module_function

        REPORT_CONTRIBUTOR = Module.new do
          module_function

          def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
            snapshot = AuditPack.snapshot(result)
            report.add_section(:audit_summary, {
                                 graph: snapshot.graph,
                                 event_count: snapshot.event_count,
                                 event_types: snapshot.event_types,
                                 state_count: snapshot.states.length,
                                 output_names: snapshot.output_names
                               })
          end
        end

        def manifest
          Igniter::Contracts::PackManifest.new(
            name: :extensions_audit,
            registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:audit_summary)],
            metadata: { category: :developer }
          )
        end

        def install_into(kernel)
          kernel.diagnostics_contributors.register(:audit_summary, REPORT_CONTRIBUTOR)
          kernel
        end

        def snapshot(result)
          Audit::Builder.build(result)
        end

        def report(environment, inputs: nil, compiled_graph: nil, &block)
          result =
            if block
              environment.run(inputs: inputs || {}, &block)
            elsif compiled_graph
              environment.execute(compiled_graph, inputs: inputs || {})
            else
              raise ArgumentError, "audit_report requires a block or compiled_graph"
            end

          snapshot(result)
        end
      end
    end
  end
end
