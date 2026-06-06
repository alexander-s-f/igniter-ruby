# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module JournalPack
        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_journal,
              registry_contracts: [
                Igniter::Contracts::PackManifest.effect(:journal),
                Igniter::Contracts::PackManifest.executor(:journaled_inline)
              ]
            )
          end

          def install_into(kernel)
            kernel.effects.register(:journal, method(:apply_journal_effect))
            kernel.executors.register(:journaled_inline, method(:execute_journaled_inline))
            kernel
          end

          def journal
            @journal ||= {
              effects: [],
              executions: [],
              results: []
            }
          end

          def reset_journal!
            journal.each_value(&:clear)
          end

          def apply_journal_effect(invocation:)
            journal[:effects] << invocation.to_h
            invocation.payload
          end

          def execute_journaled_inline(invocation:)
            journal[:executions] << invocation.to_h
            result = invocation.runtime.execute(
              invocation.compiled_graph,
              inputs: invocation.inputs,
              profile: invocation.profile
            )
            journal[:results] << result.to_h
            result
          end
        end
      end
    end
  end
end
