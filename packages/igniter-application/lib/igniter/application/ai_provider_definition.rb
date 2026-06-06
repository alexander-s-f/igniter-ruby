# frozen_string_literal: true

module Igniter
  module Application
    AIProviderDefinition = Struct.new(
      :name, :adapter, :credential, :model, :mode, :options, keyword_init: true
    ) do
      def initialize(name:, adapter: nil, credential: nil, model: nil, mode: :live, options: {})
        super(
          name: name.to_sym,
          adapter: (adapter || name).to_sym,
          credential: credential&.to_sym,
          model: model&.to_s,
          mode: mode.to_sym,
          options: options.transform_keys(&:to_sym).freeze
        )
        freeze
      end

      def build_client(credentials:)
        Igniter::AI.client(provider: build_provider(credentials: credentials))
      end

      def to_h
        {
          name: name,
          adapter: adapter,
          credential: credential,
          model: model,
          mode: mode,
          options: safe_options
        }.compact
      end

      private

      def build_provider(credentials:)
        case adapter
        when :openai, :openai_responses
          Igniter::AI::Providers::OpenAIResponses.new(
            api_key: credentials.fetch(credential || :openai_api_key),
            model: model,
            **options
          )
        when :fake
          Igniter::AI::Providers::Fake.new(**options)
        when :recorded
          Igniter::AI::Providers::Recorded.new(records: options.fetch(:records, []))
        else
          raise ArgumentError, "unknown AI provider adapter #{adapter.inspect}"
        end
      end

      def safe_options
        options.reject { |key, _value| key.to_s.include?("key") || key.to_s.include?("secret") }
      end
    end
  end
end
