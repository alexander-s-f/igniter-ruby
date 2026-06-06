# frozen_string_literal: true

module Igniter
  module Agents
    AgentDefinition = Struct.new(:name, :model, :instructions, :metadata, keyword_init: true) do
      def initialize(name, model:, instructions: nil, metadata: {})
        super(
          name: name.to_sym,
          model: model.to_s,
          instructions: instructions&.to_s,
          metadata: metadata.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def to_h
        {
          name: name,
          model: model,
          instructions: instructions,
          metadata: metadata
        }.compact
      end
    end
  end
end
