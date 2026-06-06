# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        module Formatter
          module_function

          def format(result)
            lines = []
            lines << "Status:   #{result.success? ? "SUCCESS" : "FAILED"}"
            lines << "Profile:  #{result.execution_result.profile_fingerprint}"

            unless result.success?
              lines << "Error:    #{result.error.message}"
              lines << "At node:  :#{result.failed_node}" if result.failed_node
            end

            append_compensations(result, lines)
            lines.join("\n")
          end

          def append_compensations(result, lines)
            return if result.compensations.empty?

            lines << ""
            lines << "COMPENSATIONS (#{result.compensations.length}):"
            result.compensations.each do |record|
              tag = record.success? ? "[ok]   " : "[fail] "
              lines << "  #{tag} :#{record.node_name}"
              lines << "    error: #{record.error.message}" if record.failed?
            end
          end
        end
      end
    end
  end
end
