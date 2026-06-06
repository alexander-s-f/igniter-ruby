# frozen_string_literal: true

module Igniter
  module Application
    class AIBuilder
      attr_reader :definitions

      def initialize
        @definitions = {}
      end

      def provider(name, adapter = nil, credential: nil, model: nil, mode: :live, **options)
        definition = AIProviderDefinition.new(
          name: name,
          adapter: adapter,
          credential: credential,
          model: model,
          mode: mode,
          options: options
        )
        @definitions[definition.name] = definition
        self
      end
    end
  end
end
