# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        module AggregateOperators
          Operator = Struct.new(
            :initial_fn, :project, :add, :remove, :finalize, :recompute,
            keyword_init: true
          ) do
            def initial
              initial_fn.call
            end
          end

          module_function

          def count(filter: nil)
            Operator.new(
              initial_fn: -> { 0 },
              project: ->(item) { filter.nil? || filter.call(item) ? 1 : 0 },
              add: ->(acc, value) { acc + value },
              remove: ->(acc, value) { acc - value },
              finalize: ->(acc, _) { acc },
              recompute: false
            )
          end

          def sum(projection:)
            Operator.new(
              initial_fn: -> { 0 },
              project: ->(item) { project(item, projection).to_f },
              add: ->(acc, value) { acc + value },
              remove: ->(acc, value) { acc - value },
              finalize: ->(acc, _) { acc },
              recompute: false
            )
          end

          def avg(projection:)
            Operator.new(
              initial_fn: -> { { sum: 0.0, count: 0 } },
              project: ->(item) { project(item, projection).to_f },
              add: ->(acc, value) { { sum: acc.fetch(:sum) + value, count: acc.fetch(:count) + 1 } },
              remove: ->(acc, value) { { sum: acc.fetch(:sum) - value, count: acc.fetch(:count) - 1 } },
              finalize: lambda { |acc, _|
                acc.fetch(:count).zero? ? 0.0 : acc.fetch(:sum) / acc.fetch(:count)
              },
              recompute: false
            )
          end

          def min(projection:)
            recomputed_projection(projection, &:min)
          end

          def max(projection:)
            recomputed_projection(projection, &:max)
          end

          def group_count(projection:)
            Operator.new(
              initial_fn: -> { {} },
              project: ->(item) { project(item, projection) },
              add: ->(acc, group_key) { acc.merge(group_key => (acc[group_key] || 0) + 1) },
              remove: lambda { |acc, group_key|
                count = (acc[group_key] || 1) - 1
                count <= 0 ? acc.reject { |key, _| key == group_key } : acc.merge(group_key => count)
              },
              finalize: ->(acc, _) { acc },
              recompute: false
            )
          end

          def custom(initial:, add:, remove:)
            Operator.new(
              initial_fn: -> { duplicate(initial) },
              project: ->(item) { item },
              add: ->(acc, item) { add.call(acc, item) },
              remove: ->(acc, item) { remove.call(acc, item) },
              finalize: ->(acc, _) { acc },
              recompute: false
            )
          end

          def project(item, projection)
            return item if projection.nil?
            return projection.call(item) if projection.respond_to?(:call)

            key = projection.to_sym
            return item.output(key) if item.outputs.key?(key)
            return item.input(key) if item.inputs.key?(key)

            raise KeyError,
                  "aggregate projection #{projection.inspect} not present on dataflow item #{item.key.inspect}"
          end

          def recomputed_projection(projection, &finalizer)
            Operator.new(
              initial_fn: -> { nil },
              project: ->(item) { project(item, projection) },
              add: nil,
              remove: nil,
              finalize: ->(_acc, contributions) { finalizer.call(contributions.values) },
              recompute: true
            )
          end

          def duplicate(value)
            value.frozen? ? value : value.dup
          rescue TypeError
            value
          end
        end
      end
    end
  end
end
