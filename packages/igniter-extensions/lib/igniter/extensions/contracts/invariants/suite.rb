# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Invariants
        class Suite
          attr_reader :invariants

          def initialize(invariants:)
            @invariants = invariants.freeze
            freeze
          end

          def invariant(name, &block)
            self.class.new(invariants: invariants + [Invariant.new(name, &block)])
          end

          def empty?
            invariants.empty?
          end

          def names
            invariants.map(&:name)
          end

          def to_h
            {
              invariants: names
            }
          end
        end
      end
    end
  end
end
