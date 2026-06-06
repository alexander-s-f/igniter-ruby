# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      module ConstRuntime
        module_function

        def handle_const(operation:, **)
          operation.attributes[:value]
        end
      end
    end
  end
end
