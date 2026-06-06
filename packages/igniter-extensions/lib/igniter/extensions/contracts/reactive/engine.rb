# frozen_string_literal: true

require "set"

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class Engine
          attr_reader :plan, :errors

          def initialize(plan:)
            @plan = plan
            @errors = []
            @fired = Set.new
          end

          def call(events:, result:, execution_result:, execution_error: nil)
            events.each do |event|
              plan.subscriptions.each do |subscription|
                next unless Matcher.match?(subscription, event)
                next if already_fired?(subscription, event)

                mark_fired(subscription, event)
                call_action(
                  subscription.action,
                  event: event,
                  result: result,
                  execution_result: execution_result,
                  execution_error: execution_error,
                  value: event.value,
                  status: event.status,
                  outputs: execution_result&.outputs&.to_h
                )
              rescue StandardError => e
                errors << {
                  event: event,
                  subscription: subscription,
                  error: e
                }
              end
            end
          end

          private

          def call_action(action, **kwargs)
            parameters = action.parameters
            accepts_any_keywords = parameters.any? { |kind, _name| kind == :keyrest }

            if accepts_any_keywords
              action.call(**kwargs)
              return
            end

            accepted = parameters.select { |kind, _name| %i[key keyreq].include?(kind) }.map(&:last)
            action.call(**kwargs.slice(*accepted))
          end

          def already_fired?(subscription, event)
            return false unless subscription.once_per_dispatch

            @fired.include?(firing_key(subscription, event))
          end

          def mark_fired(subscription, event)
            return unless subscription.once_per_dispatch

            @fired << firing_key(subscription, event)
          end

          def firing_key(subscription, event)
            [subscription.object_id, event.type, event.path]
          end
        end
      end
    end
  end
end
