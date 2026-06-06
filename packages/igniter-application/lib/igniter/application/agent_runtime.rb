# frozen_string_literal: true

module Igniter
  module Application
    class AgentRuntime
      attr_reader :definition, :ai_registry

      def initialize(definition:, ai_registry:)
        @definition = definition
        @ai_registry = ai_registry
      end

      def run(input:, context: {}, metadata: {}, id: nil)
        Igniter::Agents.run(
          definition.to_agent_definition(ai_registry: ai_registry),
          ai_client: ai_registry.client(definition.ai_provider),
          input: input,
          context: context,
          metadata: metadata,
          id: id
        )
      end

      def to_h
        definition.to_h
      end
    end
  end
end
