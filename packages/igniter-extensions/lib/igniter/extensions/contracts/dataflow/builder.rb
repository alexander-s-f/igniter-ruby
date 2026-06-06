# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class Builder
          attr_reader :source, :key, :window, :context

          def initialize(source:, key:, window: nil, context: [])
            @source = source.to_sym
            @key = key.to_sym
            @window = window
            @context = Array(context).map(&:to_sym).freeze
            @item_block = nil
            @aggregate_operators = {}
          end

          def item(&block)
            @item_block = block
          end

          def count(name, matching: nil)
            register(name, AggregateOperators.count(filter: matching))
          end

          def sum(name, using:)
            register(name, AggregateOperators.sum(projection: using))
          end

          def avg(name, using:)
            register(name, AggregateOperators.avg(projection: using))
          end

          def min(name, using:)
            register(name, AggregateOperators.min(projection: using))
          end

          def max(name, using:)
            register(name, AggregateOperators.max(projection: using))
          end

          def group_count(name, using:)
            register(name, AggregateOperators.group_count(projection: using))
          end

          def aggregate(name, initial:, add:, remove:)
            register(name, AggregateOperators.custom(initial: initial, add: add, remove: remove))
          end

          def build!(environment)
            raise Igniter::Contracts::Error, "DataflowPack requires an `item do ... end` definition" unless @item_block

            [environment.compile(&@item_block), @aggregate_operators.dup.freeze]
          end

          private

          def register(name, operator)
            @aggregate_operators[name.to_sym] = operator
          end
        end
      end
    end
  end
end
