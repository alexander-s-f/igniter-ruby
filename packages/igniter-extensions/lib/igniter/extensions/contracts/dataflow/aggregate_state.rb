# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class AggregateState
          def initialize(operator)
            @operator = operator
            @contributions = {}
            @accum = operator.initial
          end

          def apply_diff!(diff, collection_result)
            diff.changed.each do |key|
              retract!(key)
              contribute!(key, collection_result[key])
            end

            diff.added.each do |key|
              contribute!(key, collection_result[key])
            end

            diff.removed.each do |key|
              retract!(key)
            end
          end

          def value
            if @operator.recompute
              @operator.finalize.call(nil, @contributions)
            else
              @operator.finalize.call(@accum, @contributions.size)
            end
          end

          private

          def contribute!(key, item)
            contribution = @operator.project.call(item)
            return if contribution.nil?

            @contributions[key] = contribution
            return if @operator.recompute

            @accum = @operator.add.call(@accum, contribution)
          end

          def retract!(key)
            old_contribution = @contributions.delete(key)
            return unless old_contribution
            return if @operator.recompute

            @accum = @operator.remove.call(@accum, old_contribution)
          end
        end
      end
    end
  end
end
