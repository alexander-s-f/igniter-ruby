# frozen_string_literal: true

module Igniter
  module Application
    class AgentsBuilder
      attr_reader :definitions

      def initialize
        @definitions = {}
      end

      def assistant(name, model: nil, instructions: nil, **options)
        ai_provider = options.delete(:ai) || :default
        definition = AgentDefinition.new(
          name: name,
          ai_provider: ai_provider,
          model: model,
          instructions: instructions,
          metadata: options
        )
        @definitions[definition.name] = definition
        self
      end
    end
  end
end
