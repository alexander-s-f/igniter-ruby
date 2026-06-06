# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class Plan
          attr_reader :subscriptions

          def initialize(subscriptions:)
            @subscriptions = subscriptions.freeze
            freeze
          end

          def react_to(event_type, path: nil, once_per_dispatch: false, &block)
            with_subscription(
              Subscription.new(
                event_type: event_type,
                path: path,
                action: block,
                once_per_dispatch: once_per_dispatch
              )
            )
          end

          def effect(path, &block)
            react_to(:output_produced, path: path, &block)
          end

          def on_success(path = nil, &block)
            event_type = path.nil? ? :execution_succeeded : :output_produced
            react_to(event_type, path: path, once_per_dispatch: true, &block)
          end

          def on_failure(&block)
            react_to(:execution_failed, once_per_dispatch: true, &block)
          end

          def on_exit(&block)
            react_to(:execution_exited, once_per_dispatch: true, &block)
          end

          def to_h
            {
              subscriptions: subscriptions.map(&:to_h)
            }
          end

          private

          def with_subscription(subscription)
            self.class.new(subscriptions: subscriptions + [subscription])
          end
        end
      end
    end
  end
end
