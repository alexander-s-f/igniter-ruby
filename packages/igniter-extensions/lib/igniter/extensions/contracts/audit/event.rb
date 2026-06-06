# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Audit
        class Event
          attr_reader :event_id, :type, :node_name, :path, :status, :payload

          def initialize(event_id:, type:, node_name:, path:, status:, payload: {})
            @event_id = event_id.to_s
            @type = type.to_sym
            @node_name = node_name.to_sym
            @path = Array(path).map(&:to_sym).freeze
            @status = status.to_sym
            @payload = payload.freeze
            freeze
          end

          def to_h
            {
              event_id: event_id,
              type: type,
              node_name: node_name,
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
