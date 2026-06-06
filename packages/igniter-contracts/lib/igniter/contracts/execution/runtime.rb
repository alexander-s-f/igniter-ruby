# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class Runtime
        class << self
          def execute(compiled_graph, inputs:, profile:)
            validate_profile!(compiled_graph, profile: profile)

            normalized_inputs = NamedValues.new(inputs)
            state = MutableNamedValues.new
            outputs = MutableNamedValues.new

            compiled_graph.operations.each do |operation|
              handler = profile.runtime_handler(operation.kind)
              value = handler.call(operation: operation, state: state, outputs: outputs, inputs: normalized_inputs,
                                   profile: profile)
              state.write(operation.name, value) unless operation.output?
              outputs.write(operation.name, value) if operation.output?
            end

            ExecutionResult.new(
              state: state.snapshot,
              outputs: outputs.snapshot,
              profile_fingerprint: profile.fingerprint,
              compiled_graph: compiled_graph
            )
          end

          private

          def validate_profile!(compiled_graph, profile:)
            return if compiled_graph.profile_fingerprint == profile.fingerprint

            raise ProfileMismatchError,
                  "compiled graph fingerprint #{compiled_graph.profile_fingerprint} does not match profile #{profile.fingerprint}"
          end
        end
      end
    end
  end
end
