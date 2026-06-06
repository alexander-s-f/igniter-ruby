# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class ExecutionResult
        attr_reader :state, :outputs, :profile_fingerprint, :compiled_graph

        def initialize(state:, outputs:, profile_fingerprint:, compiled_graph:)
          @state = state
          @outputs = outputs
          @profile_fingerprint = profile_fingerprint
          @compiled_graph = compiled_graph
          freeze
        end

        def output(name)
          outputs.fetch(name.to_sym)
        end

        def to_h
          {
            state: state.to_h,
            outputs: outputs.to_h,
            profile_fingerprint: profile_fingerprint,
            compiled_graph: compiled_graph.to_h
          }
        end
      end
    end
  end
end
