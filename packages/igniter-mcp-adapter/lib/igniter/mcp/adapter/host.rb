# frozen_string_literal: true

require "json"

module Igniter
  module MCP
    module Adapter
      class Host
        JSONRPC_VERSION = "2.0"
        PROTOCOL_VERSION = "2024-11-05"

        attr_reader :target

        def initialize(target: nil)
          @target = target || default_target
        end

        def serve(input: $stdin, output: $stdout)
          loop do
            message = read_message(input)
            break unless message

            response = handle_message(message)
            write_message(output, response) if response
          end
        end

        def handle_message(message)
          payload = symbolize_keys(message)
          method = payload.fetch(:method)
          id = payload[:id]

          case method
          when "initialize"
            success(id, {
                      protocolVersion: PROTOCOL_VERSION,
                      serverInfo: {
                        name: "igniter-mcp-adapter",
                        version: adapter_version
                      },
                      capabilities: {
                        tools: {
                          listChanged: false
                        }
                      }
                    })
          when "notifications/initialized"
            nil
          when "ping"
            success(id, {})
          when "tools/list"
            success(id, { tools: Server.tools })
          when "tools/call"
            params = payload.fetch(:params, {})
            validate_tool_call!(params)
            result = Server.call(
              params.fetch(:name),
              target: target,
              arguments: params.fetch(:arguments, {})
            )
            success(id, result.slice(:content, :structuredContent, :isError, :meta))
          else
            error(id, -32_601, "Method not found: #{method}")
          end
        rescue KeyError => e
          error(id, -32_602, "Invalid params: #{e.message}")
        rescue ArgumentError => e
          error(id, -32_602, "Invalid params: #{e.message}")
        rescue StandardError => e
          error(id, -32_603, "#{e.class}: #{e.message}")
        end

        def read_message(input)
          headers = {}

          loop do
            line = input.gets
            return nil unless line

            stripped = line.strip
            break if stripped.empty?

            key, value = line.split(":", 2)
            headers[key.downcase] = value.to_s.strip
          end

          length = Integer(headers.fetch("content-length"))
          body = input.read(length)
          return nil unless body

          JSON.parse(body, symbolize_names: true)
        end

        def write_message(output, payload)
          body = JSON.generate(payload)
          output.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          output.flush if output.respond_to?(:flush)
          payload
        end

        private

        def default_target
          Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::McpPack)
        end

        def validate_tool_call!(params)
          tool_name = params.fetch(:name)
          arguments = symbolize_keys(params.fetch(:arguments, {}))
          schema = Server.tool(tool_name).fetch(:inputSchema)

          validate_required_keys!(schema, arguments)
          validate_unknown_keys!(schema, arguments)
          validate_argument_values!(schema, arguments)
        end

        def validate_required_keys!(schema, arguments)
          required = Array(schema[:required]).map(&:to_sym)
          missing = required.reject { |key| arguments.key?(key) }
          return if missing.empty?

          raise ArgumentError, "missing required arguments: #{missing.join(", ")}"
        end

        def validate_unknown_keys!(schema, arguments)
          return unless schema[:additionalProperties] == false

          allowed = schema.fetch(:properties).keys.map(&:to_sym)
          unknown = arguments.keys.reject { |key| allowed.include?(key) }
          return if unknown.empty?

          raise ArgumentError, "unknown arguments: #{unknown.join(", ")}"
        end

        def validate_argument_values!(schema, arguments)
          properties = schema.fetch(:properties)

          arguments.each do |key, value|
            argument_schema = properties[key.to_s]
            next unless argument_schema

            validate_argument_type!(key, argument_schema, value)
            validate_argument_enum!(key, argument_schema, value)
          end
        end

        def validate_argument_type!(key, schema, value)
          any_of = schema[:anyOf]
          return if any_of&.any? { |candidate| valid_type?(candidate[:type], value) }
          return unless schema.key?(:type)
          return if valid_type?(schema[:type], value)

          raise ArgumentError, "argument #{key} expected #{schema[:type]}"
        end

        def validate_argument_enum!(key, schema, value)
          enum = schema[:enum]
          return if enum.nil? || enum.empty?

          comparable =
            case value
            when Symbol
              value.to_s
            else
              value
            end

          return if enum.include?(comparable)

          raise ArgumentError, "argument #{key} must be one of: #{enum.join(", ")}"
        end

        def valid_type?(type, value)
          case type
          when "string"
            value.is_a?(String) || value.is_a?(Symbol)
          when "array"
            value.is_a?(Array)
          when "object"
            value.is_a?(Hash)
          else
            true
          end
        end

        def adapter_version
          Gem.loaded_specs["igniter-mcp-adapter"]&.version&.to_s ||
            Gem.loaded_specs["igniter-extensions"]&.version&.to_s ||
            "0.0.0"
        end

        def success(id, result)
          {
            jsonrpc: JSONRPC_VERSION,
            id: id,
            result: result
          }
        end

        def error(id, code, message)
          {
            jsonrpc: JSONRPC_VERSION,
            id: id,
            error: {
              code: code,
              message: message
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
