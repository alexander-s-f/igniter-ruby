# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module InlineExecutor
        module_function

        def call(invocation:)
          invocation.runtime.execute(
            invocation.compiled_graph,
            inputs: invocation.inputs,
            profile: invocation.profile
          )
        end
      end
    end
  end
end
