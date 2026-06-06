# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Differential
        module Formatter
          module_function

          VALUE_MAX = 60

          def format(report)
            lines = []
            lines << "Primary:    #{report.primary_name}"
            lines << "Candidate:  #{report.candidate_name}"
            lines << "Match:      #{report.match? ? "YES" : "NO"}"

            if report.primary_error
              lines << ""
              lines << "PRIMARY ERROR: #{report.primary_error.fetch(:message)}"
              return lines.join("\n")
            end

            if report.candidate_error
              lines << ""
              lines << "CANDIDATE ERROR: #{report.candidate_error.fetch(:message)}"
            end

            lines << ""

            if report.divergences.empty? && report.primary_only.empty? && report.candidate_only.empty?
              lines << "All shared outputs match."
            else
              append_divergences(report, lines)
              append_only_section("CANDIDATE ONLY", report.candidate_only, lines)
              append_only_section("PRIMARY ONLY", report.primary_only, lines)
            end

            lines.join("\n")
          end

          def append_divergences(report, lines)
            return if report.divergences.empty?

            lines << "DIVERGENCES (#{report.divergences.size}):"
            report.divergences.each do |divergence|
              lines << "  :#{divergence.output_name}"
              lines << "    primary:   #{fmt(divergence.primary_value)}"
              lines << "    candidate: #{fmt(divergence.candidate_value)}"
              next if divergence.delta.nil?

              delta = divergence.delta
              lines << "    delta:     #{delta >= 0 ? "+#{delta}" : delta}"
            end
            lines << ""
          end

          def append_only_section(label, values, lines)
            return if values.empty?

            lines << "#{label} (#{values.size}):"
            values.each do |name, value|
              lines << "  :#{name} = #{fmt(value)}"
            end
            lines << ""
          end

          def fmt(value)
            string =
              case value
              when nil then "nil"
              when String, Symbol then value.inspect
              when Hash then "{#{value.map { |key, item| "#{key}: #{item.inspect}" }.join(", ")}}"
              when Array then "[#{value.map(&:inspect).join(", ")}]"
              else
                value.inspect
              end

            string.length > VALUE_MAX ? "#{string[0, VALUE_MAX - 3]}..." : string
          end
        end
      end
    end
  end
end
