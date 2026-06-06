# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class Builder
          attr_reader :plan

          def initialize
            @plan = Plan.new(subscriptions: [])
          end

          def react_to(event_type, path: nil, once_per_dispatch: false, &block)
            @plan = plan.react_to(event_type, path: path, once_per_dispatch: once_per_dispatch, &block)
          end

          def effect(path, &block)
            @plan = plan.effect(path, &block)
          end

          def on_success(path = nil, &block)
            @plan = plan.on_success(path, &block)
          end

          def on_failure(&block)
            @plan = plan.on_failure(&block)
          end

          def on_exit(&block)
            @plan = plan.on_exit(&block)
          end

          def self.build(&block)
            builder = new
            builder.instance_eval(&block) if block
            builder.plan
          end
        end
      end
    end
  end
end
