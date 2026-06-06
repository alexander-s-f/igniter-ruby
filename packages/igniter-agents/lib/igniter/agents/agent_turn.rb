# frozen_string_literal: true

module Igniter
  module Agents
    AgentTurn = Struct.new(:index, :request, :response, :tool_calls, keyword_init: true) do
      def initialize(index:, request:, response:, tool_calls: [])
        super(
          index: Integer(index),
          request: request,
          response: response,
          tool_calls: tool_calls.freeze
        )
        freeze
      end

      def text
        response.text
      end

      def success?
        response.success?
      end

      def to_h
        {
          index: index,
          request: request.to_h,
          response: response.to_h,
          tool_calls: tool_calls.map(&:to_h)
        }
      end
    end
  end
end
