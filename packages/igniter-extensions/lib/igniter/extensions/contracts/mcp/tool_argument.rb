# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Mcp
        class ToolArgument
          attr_reader :name, :type, :summary, :required, :default, :enum

          def initialize(name:, type:, summary:, required: false, default: nil, enum: nil)
            @name = name.to_sym
            @type = type.to_sym
            @summary = summary
            @required = required == true
            @default = default
            @enum = Array(enum).map(&:to_sym).freeze
            freeze
          end

          def to_h
            payload = {
              name: name,
              type: type,
              summary: summary,
              required: required
            }
            payload[:default] = default unless default.nil?
            payload[:enum] = enum unless enum.empty?
            payload
          end
        end
      end
    end
  end
end
