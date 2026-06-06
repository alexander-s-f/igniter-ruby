# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class Subscription
          attr_reader :event_type, :path, :action, :once_per_dispatch

          def initialize(event_type:, action:, path: nil, once_per_dispatch: false)
            @event_type = event_type.to_sym
            @path = path&.to_sym
            @action = action
            @once_per_dispatch = once_per_dispatch
            freeze
          end

          def to_h
            {
              event_type: event_type,
              path: path,
              once_per_dispatch: once_per_dispatch
            }
          end
        end
      end
    end
  end
end
