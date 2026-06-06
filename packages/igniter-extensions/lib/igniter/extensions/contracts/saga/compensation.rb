# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        class Compensation
          attr_reader :node_name, :block

          def initialize(node_name, &block)
            raise ArgumentError, "compensate :#{node_name} requires a block" unless block

            @node_name = node_name.to_sym
            @block = block
            freeze
          end

          def run(inputs:, value:)
            block.call(inputs: inputs, value: value)
          end
        end
      end
    end
  end
end
