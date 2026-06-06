# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Saga
        class CompensationSet
          def self.build(&block)
            new.tap do |set|
              set.instance_eval(&block) if block
              set.finalize!
            end
          end

          def initialize
            @compensations = {}
          end

          def compensate(node_name, &block)
            @compensations[node_name.to_sym] = Compensation.new(node_name, &block)
          end

          def [](node_name)
            @compensations[node_name.to_sym]
          end

          def key?(node_name)
            @compensations.key?(node_name.to_sym)
          end

          def to_h
            @compensations.dup
          end

          def keys
            @compensations.keys
          end

          def finalize!
            @compensations.freeze
            freeze
          end
        end
      end
    end
  end
end
