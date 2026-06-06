# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Invariant
          attr_reader :name, :block

          def initialize(name, &block)
            raise ArgumentError, "invariant #{name.inspect} requires a block" unless block

            @name = name.to_sym
            @block = block
            freeze
          end

          def check(outputs)
            passed = block.call(**outputs)
            return nil if passed

            Violation.new(name: name, outputs: outputs)
          rescue StandardError => e
            Violation.new(name: name, outputs: outputs, error: e)
          end
        end
      end
    end
  end
end
