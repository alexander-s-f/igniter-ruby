# frozen_string_literal: true

module Igniter
  module Application
    AgentDefinition = Struct.new(:name, :ai_provider, :model, :instructions, :metadata, keyword_init: true) do
      def initialize(name:, ai_provider: :default, model: nil, instructions: nil, metadata: {})
        super(
          name: name.to_sym,
          ai_provider: ai_provider.to_sym,
          model: model&.to_s,
          instructions: instructions&.to_s,
          metadata: metadata.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def to_agent_definition(ai_registry:)
        provider = ai_registry.definition(ai_provider)
        Igniter::Agents.agent(
          name,
          model: model || provider.model || ai_provider.to_s,
          instructions: instructions,
          metadata: metadata.merge(ai_provider: ai_provider)
        )
      end

      def to_h
        {
          name: name,
          ai_provider: ai_provider,
          model: model,
          instructions: instructions,
          metadata: metadata
        }.compact
      end
    end
  end
end
