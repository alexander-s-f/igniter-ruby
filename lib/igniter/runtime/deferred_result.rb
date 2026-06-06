# frozen_string_literal: true

require "securerandom"

module Igniter
  module Runtime
    unless const_defined?(:DeferredResult)
      class DeferredResult
        attr_reader :token, :payload, :source_node, :waiting_on

        def initialize(token:, payload: {}, source_node: nil, waiting_on: nil)
          @token = token
          @payload = payload.freeze
          @source_node = source_node&.to_sym
          @waiting_on = waiting_on&.to_sym
        end

        def self.build(token: nil, payload: {}, source_node: nil, waiting_on: nil)
          new(
            token: token || SecureRandom.uuid,
            payload: payload,
            source_node: source_node,
            waiting_on: waiting_on
          )
        end

        def to_h
          {
            token: token,
            payload: payload,
            source_node: source_node,
            waiting_on: waiting_on,
            agent_result_contract: agent_result_contract&.to_h
          }.compact
        end

        def as_json(*)
          to_h
        end

        def routing_trace
          payload[:routing_trace] || payload["routing_trace"]
        end

        def agent_trace
          payload[:agent_trace] || payload["agent_trace"]
        end

        def agent_session_data
          payload[:agent_session] || payload["agent_session"]
        end

        def session
          data = agent_session_data
          return nil unless data

          Runtime::AgentSession.from_h(data)
        end

        def agent_result_contract
          Runtime::AgentResultContract.from_result(self, kind: :deferred)
        end

        alias interaction_result_contract agent_result_contract
      end
    end
  end
end
