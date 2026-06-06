# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Incremental
        class Result
          attr_reader :execution_result, :changed_nodes, :skipped_nodes, :backdated_nodes,
                      :changed_outputs, :recomputed_count

          def initialize(execution_result:, changed_nodes:, skipped_nodes:, backdated_nodes:, changed_outputs:,
                         recomputed_count:)
            @execution_result = execution_result
            @changed_nodes = changed_nodes.freeze
            @skipped_nodes = skipped_nodes.freeze
            @backdated_nodes = backdated_nodes.freeze
            @changed_outputs = changed_outputs.freeze
            @recomputed_count = recomputed_count
            freeze
          end

          def outputs_changed?
            changed_outputs.any?
          end

          def fully_memoized?
            recomputed_count.zero?
          end

          def summary
            parts = []
            parts << "#{changed_nodes.length} changed" if changed_nodes.any?
            parts << "#{skipped_nodes.length} skipped" if skipped_nodes.any?
            parts << "#{backdated_nodes.length} backdated" if backdated_nodes.any?
            parts << "#{recomputed_count} recomputed"
            parts.join(", ")
          end

          def explain
            Formatter.format(self)
          end

          alias to_s explain

          def output(name)
            execution_result.output(name)
          end

          def to_h
            {
              changed_nodes: changed_nodes,
              skipped_nodes: skipped_nodes,
              backdated_nodes: backdated_nodes,
              changed_outputs: changed_outputs,
              recomputed_count: recomputed_count,
              outputs_changed: outputs_changed?,
              fully_memoized: fully_memoized?,
              execution_result: execution_result.to_h
            }
          end
        end
      end
    end
  end
end
