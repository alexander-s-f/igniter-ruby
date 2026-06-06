# frozen_string_literal: true

require "igniter/extensions/contracts"

module Igniter
  module MCP
    module Adapter
      module_function

      def tool_catalog
        Igniter::Extensions::Contracts.mcp_tools
      end

      def tool_names
        tool_catalog.map { |tool| tool.fetch(:name) }
      end

      def tool_definition(tool_name)
        tool_catalog.find { |tool| tool.fetch(:name) == tool_name.to_sym } ||
          raise(ArgumentError, "unknown MCP adapter tool #{tool_name.inspect}")
      end

      def invoke(tool_name, target: nil, **arguments, &block)
        Igniter::Extensions::Contracts.mcp_call(
          tool_name,
          target: target,
          **arguments,
          &block
        )
      end

      def creator_session(target: nil, **arguments)
        Igniter::Extensions::Contracts.mcp_creator_session(
          target: target,
          **arguments
        )
      end
    end
  end
end
