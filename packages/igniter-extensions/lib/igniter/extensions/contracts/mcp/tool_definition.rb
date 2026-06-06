# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Mcp
        class ToolDefinition
          attr_reader :name, :summary, :mutating, :target, :arguments

          def initialize(name:, summary:, mutating: false, target: nil, arguments: [])
            @name = name.to_sym
            @summary = summary
            @mutating = mutating == true
            @target = target&.to_sym
            @arguments = arguments.freeze
            freeze
          end

          def to_h
            payload = {
              name: name,
              summary: summary,
              mutating: mutating,
              arguments: arguments.map(&:to_h)
            }
            payload[:target] = target if target
            payload
          end
        end
      end
    end
  end
end
