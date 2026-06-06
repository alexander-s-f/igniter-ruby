# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class ExecutionRequest
        attr_reader :compiled_graph, :inputs, :profile, :runtime

        def initialize(compiled_graph:, inputs:, profile:, runtime:)
          @compiled_graph = compiled_graph
          @inputs = inputs.is_a?(NamedValues) ? inputs : NamedValues.new(inputs)
          @profile = profile
          @runtime = runtime
          freeze
        end

        def to_h
          {
            compiled_graph: StructuredDump.dump(compiled_graph),
            inputs: inputs.to_h,
            profile_fingerprint: profile.fingerprint,
            runtime: runtime.name
          }
        end
      end
    end
  end
end
