# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Provenance
        class Lineage
          attr_reader :trace

          def initialize(trace)
            @trace = trace
            freeze
          end

          def output_name
            trace.name
          end

          def value
            trace.value
          end

          def contributing_inputs
            trace.contributing_inputs
          end

          def sensitive_to?(input_name)
            trace.sensitive_to?(input_name)
          end

          def path_to(input_name)
            trace.path_to(input_name)
          end

          def explain
            TextFormatter.format(trace)
          end

          alias to_s explain

          def to_h
            serialize(trace)
          end

          private

          def serialize(trace)
            {
              node: trace.name,
              kind: trace.kind,
              value: trace.value,
              contributing: trace.contributing.transform_values { |dependency| serialize(dependency) }
            }
          end
        end
      end
    end
  end
end
