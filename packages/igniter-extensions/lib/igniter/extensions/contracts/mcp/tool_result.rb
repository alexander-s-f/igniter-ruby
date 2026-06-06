# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Mcp
        class ToolResult
          attr_reader :tool_name, :payload, :mutating

          def initialize(tool_name:, payload:, mutating:)
            @tool_name = tool_name.to_sym
            @payload = payload
            @mutating = mutating == true
            freeze
          end

          def to_h
            {
              tool_name: tool_name,
              mutating: mutating,
              payload: payload
            }
          end
        end
      end
    end
  end
end
