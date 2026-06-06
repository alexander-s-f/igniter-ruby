# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Incremental
        module Formatter
          module_function

          LINE = "─" * 42
          VALUE_MAX = 60

          def format(result)
            lines = []
            lines << "Contracts Incremental Report"
            lines << LINE
            lines << "Recomputed:  #{result.recomputed_count} node(s)"
            lines << "Skipped:     #{result.skipped_nodes.length} node(s)"
            lines << "Backdated:   #{result.backdated_nodes.length} node(s)"
            lines << ""

            if result.changed_outputs.any?
              lines << "CHANGED OUTPUTS (#{result.changed_outputs.length}):"
              result.changed_outputs.each do |name, diff|
                lines << "  :#{name}  #{fmt(diff[:from])} -> #{fmt(diff[:to])}"
              end
            else
              lines << "No output values changed."
            end

            lines << ""
            if result.skipped_nodes.any?
              lines << "SKIPPED:   #{result.skipped_nodes.map do |name|
                ":#{name}"
              end.join("  ")}"
            end
            if result.backdated_nodes.any?
              lines << "BACKDATED: #{result.backdated_nodes.map do |name|
                ":#{name}"
              end.join("  ")}"
            end
            if result.changed_nodes.any?
              lines << "CHANGED:   #{result.changed_nodes.map do |name|
                ":#{name}"
              end.join("  ")}"
            end
            lines.compact.join("\n")
          end

          def fmt(value)
            rendered = value.inspect
            return rendered if rendered.length <= VALUE_MAX

            "#{rendered[0, VALUE_MAX - 3]}..."
          end
        end
      end
    end
  end
end
