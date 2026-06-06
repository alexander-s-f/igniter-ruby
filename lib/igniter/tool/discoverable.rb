# frozen_string_literal: true

module Igniter
  class Tool
    module Discoverable
      JSON_TYPES = {
        string: "string", str: "string",
        integer: "integer", int: "integer",
        float: "number", number: "number",
        boolean: "boolean", bool: "boolean",
        array: "array",
        object: "object"
      }.freeze

      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@tool_params, [])
        base.instance_variable_set(:@required_capabilities, [].freeze)
      end

      module ClassMethods
        def description(text = nil)
          text ? (@tool_description = text.freeze) : @tool_description
        end

        def param(name, type:, required: false, default: nil, desc: nil)
          tool_params << {
            name: name.to_sym,
            type: type.to_sym,
            required: required,
            default: default,
            desc: desc.to_s
          }.freeze
        end

        def requires_capability(*caps)
          @required_capabilities = caps.flatten.map(&:to_sym).freeze
        end

        def tool_params
          @tool_params ||= []
        end

        def required_capabilities
          @required_capabilities || [].freeze
        end

        def tool_name
          n = name.to_s.split("::").last
          return "anonymous" if n.nil? || n.empty?

          n.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
        end

        def to_schema(provider = nil)
          case provider&.to_sym
          when :anthropic
            { name: tool_name, description: description.to_s, input_schema: json_schema }
          when :openai
            {
              type: "function",
              function: { name: tool_name, description: description.to_s, parameters: json_schema }
            }
          else
            { name: tool_name, description: description.to_s, parameters: json_schema }
          end
        end

        def copy_discoverable_state_to(subclass)
          subclass.instance_variable_set(:@tool_params, @tool_params&.dup || [])
          subclass.instance_variable_set(:@required_capabilities, @required_capabilities&.dup || [].freeze)
          subclass.instance_variable_set(:@tool_description, @tool_description)
        end

        private

        def json_schema
          required_names = tool_params.select { |p| p[:required] }.map { |p| p[:name].to_s }
          properties = tool_params.each_with_object({}) do |p, h|
            prop = { "type" => JSON_TYPES.fetch(p[:type], "string") }
            prop["description"] = p[:desc] unless p[:desc].empty?
            prop["default"] = p[:default] unless p[:default].nil?
            h[p[:name].to_s] = prop
          end

          schema = { "type" => "object", "properties" => properties }
          schema["required"] = required_names unless required_names.empty?
          schema
        end
      end

      def call_with_capability_check!(allowed_capabilities:, **kwargs)
        required = self.class.required_capabilities
        unless required.empty?
          allowed = allowed_capabilities.map(&:to_sym)
          missing = required.reject { |c| allowed.include?(c) }
          unless missing.empty?
            raise Igniter::Tool::CapabilityError,
                  "Tool #{self.class.tool_name.inspect} requires capabilities " \
                  "#{missing.inspect} but agent only has #{allowed.inspect}"
          end
        end
        call(**kwargs)
      end
    end
  end
end
