# frozen_string_literal: true

module Igniter
  module Agents
    ToolCall = Struct.new(:name, :input, :result, :status, keyword_init: true) do
      def initialize(name:, input:, result: nil, status: :pending)
        super(
          name: name.to_sym,
          input: input,
          result: result,
          status: status.to_sym
        )
        freeze
      end

      def to_h
        {
          name: name,
          input: input,
          result: result,
          status: status
        }
      end
    end
  end
end
