# frozen_string_literal: true

require "json"

module Igniter
  module MCP
    module Adapter
      module Server
        module_function

        def tools
          Adapter.tool_catalog.map { |tool| transport_tool(tool) }
        end

        def tool(name)
          transport_tool(Adapter.tool_definition(name))
        end

        def call(name, arguments: {}, target: nil, &block)
          result = Adapter.invoke(
            name,
            target: target,
            **symbolize_keys(arguments),
            &block
          )

          transport_result(result)
        rescue StandardError => e
          error_result(name, e)
        end

        def transport_tool(tool)
          {
            name: tool.fetch(:name).to_s,
            description: tool.fetch(:summary),
            inputSchema: input_schema(tool),
            annotations: {
              title: tool.fetch(:name).to_s,
              readOnlyHint: !tool.fetch(:mutating),
              idempotentHint: !tool.fetch(:mutating)
            }
          }
        end

        def input_schema(tool)
          arguments = tool.fetch(:arguments)
          required_arguments = arguments.select { |argument| argument.fetch(:required) }

          {
            type: "object",
            properties: arguments.to_h do |argument|
              [argument.fetch(:name).to_s, argument_schema(argument)]
            end,
            required: required_arguments.map { |argument| argument.fetch(:name).to_s },
            additionalProperties: false
          }
        end

        def argument_schema(argument)
          schema = {
            description: argument.fetch(:summary)
          }

          case argument.fetch(:type).to_sym
          when :string
            schema[:type] = "string"
          when :symbol
            schema[:type] = "string"
          when :symbol_array
            schema[:type] = "array"
            schema[:items] = { type: "string" }
          when :map, :session_state, :compiled_graph
            schema[:type] = "object"
          when :pack_reference
            schema[:anyOf] = [
              { type: "string" },
              { type: "object" }
            ]
          else
            schema[:type] = "object"
          end

          argument_enum = argument[:enum] || []
          schema[:enum] = argument_enum.map(&:to_s) unless argument_enum.empty?

          default = argument[:default]
          schema[:default] = default.is_a?(Symbol) ? default.to_s : default unless default.nil?

          schema
        end

        def transport_result(result)
          payload = result.to_h
          structured = payload.fetch(:payload)

          {
            tool: payload.fetch(:tool_name).to_s,
            isError: false,
            structuredContent: structured,
            content: [
              {
                type: "text",
                text: JSON.generate(structured)
              }
            ],
            meta: {
              mutating: payload.fetch(:mutating)
            }
          }
        end

        def error_result(name, error)
          message = "#{error.class}: #{error.message}"

          {
            tool: name.to_s,
            isError: true,
            content: [
              {
                type: "text",
                text: message
              }
            ],
            structuredContent: {
              error: {
                class: error.class.name,
                message: error.message
              }
            }
          }
        end

        def symbolize_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested), memo|
              memo[key.respond_to?(:to_sym) ? key.to_sym : key] = symbolize_keys(nested)
            end
          when Array
            value.map { |item| symbolize_keys(item) }
          else
            value
          end
        end
      end
    end
  end
end
