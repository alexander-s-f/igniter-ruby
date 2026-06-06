# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        class Event
          attr_reader :event_id, :type, :path, :status, :payload

          def initialize(event_id:, type:, path:, status:, payload: {})
            @event_id = event_id.to_s
            @type = type.to_sym
            @path = path&.to_sym
            @status = status.to_sym
            @payload = payload.freeze
            freeze
          end

          def value
            payload[:value]
          end

          def to_h
            {
              event_id: event_id,
              type: type,
              path: path,
              status: status,
              payload: payload
            }
          end
        end
      end
    end
  end
end
