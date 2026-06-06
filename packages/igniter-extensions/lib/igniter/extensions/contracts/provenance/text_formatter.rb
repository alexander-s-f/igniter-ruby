# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Provenance
        module TextFormatter
          VALUE_MAX_LENGTH = 60

          module_function

          def format(trace)
            lines = []
            render(trace, lines, prefix: "", is_root: true, is_last: true)
            lines.join("\n")
          end

          def render(trace, lines, prefix:, is_root:, is_last:)
            if is_root
              connector = ""
              child_padding = ""
            elsif is_last
              connector = "└─ "
              child_padding = "   "
            else
              connector = "├─ "
              child_padding = "│  "
            end

            child_prefix = prefix + child_padding
            lines << "#{prefix}#{connector}#{trace.name} = #{format_value(trace.value)}  [#{trace.kind}]"

            dependencies = trace.contributing.values
            dependencies.each_with_index do |dependency, index|
              render(
                dependency,
                lines,
                prefix: child_prefix,
                is_root: false,
                is_last: index == dependencies.length - 1
              )
            end
          end

          def format_value(value)
            rendered = case value
                       when nil then "nil"
                       when String, Symbol then value.inspect
                       when Hash then "{#{value.map { |key, entry| "#{key}: #{entry.inspect}" }.join(", ")}}"
                       when Array then "[#{value.map(&:inspect).join(", ")}]"
                       else value.inspect
                       end

            return rendered if rendered.length <= VALUE_MAX_LENGTH

            "#{rendered[0, VALUE_MAX_LENGTH - 3]}..."
          end
        end
      end
    end
  end
end
