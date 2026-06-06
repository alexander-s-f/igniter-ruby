# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class CollectionResult
          include Enumerable

          attr_reader :items, :diff

          def initialize(items:, diff:)
            @items = items.dup.freeze
            @diff = diff
            freeze
          end

          def [](key)
            items[key]
          end

          def fetch(key)
            items.fetch(key)
          end

          def each(&block)
            items.each(&block)
          end

          def each_value(&block)
            items.each_value(&block)
          end

          def keys
            items.keys
          end

          def values
            items.values
          end

          def successes
            items
          end

          def summary
            {
              mode: :incremental,
              total: items.size,
              succeeded: items.size,
              failed: 0,
              status: :success,
              added: diff.added.size,
              removed: diff.removed.size,
              changed: diff.changed.size,
              unchanged: diff.unchanged.size
            }
          end

          def to_h
            {
              items: items.transform_values(&:to_h),
              diff: diff.to_h
            }
          end
        end
      end
    end
  end
end
