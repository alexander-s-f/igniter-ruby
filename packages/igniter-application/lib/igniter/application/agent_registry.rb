# frozen_string_literal: true

module Igniter
  module Application
    class AgentRegistry
      attr_reader :definitions, :ai_registry

      def initialize(definitions:, ai_registry:)
        @definitions = definitions.each_with_object({}) do |definition, memo|
          memo[definition.name] = definition
        end.freeze
        @ai_registry = ai_registry
        @runtimes = {}
      end

      def runtime(name)
        key = name.to_sym
        @runtimes[key] ||= AgentRuntime.new(
          definition: definitions.fetch(key),
          ai_registry: ai_registry
        )
      end

      def names
        definitions.keys.sort
      end

      def to_h
        definitions.values.map(&:to_h).sort_by { |entry| entry.fetch(:name).to_s }
      end
    end
  end
end
