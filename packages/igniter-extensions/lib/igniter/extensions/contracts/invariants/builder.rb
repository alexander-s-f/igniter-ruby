# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Builder
          attr_reader :suite

          def initialize
            @suite = Suite.new(invariants: [])
          end

          def invariant(name, &block)
            @suite = suite.invariant(name, &block)
          end

          def self.build(&block)
            builder = new
            builder.instance_eval(&block) if block
            builder.suite
          end
        end
      end
    end
  end
end
