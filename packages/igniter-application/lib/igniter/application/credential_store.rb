# frozen_string_literal: true

module Igniter
  module Application
    class CredentialStore
      attr_reader :definitions, :env_lookup

      def initialize(definitions: [], env_lookup: ENV)
        @definitions = definitions.each_with_object({}) do |definition, memo|
          memo[definition.name] = definition
        end.freeze
        @env_lookup = env_lookup
        freeze
      end

      def names
        definitions.keys.sort
      end

      def key?(name)
        definitions.key?(name.to_sym)
      end

      def fetch(name, default: :__igniter_missing__)
        definition = definition_for(name)
        value = definition.resolve(env_lookup: env_lookup)
        return value unless value.nil?
        return default unless default == :__igniter_missing__

        raise MissingCredentialError.new(definition.name, env: definition.env)
      end

      def configured?(name)
        !definition_for(name).resolve(env_lookup: env_lookup).nil?
      end

      def status(name)
        definition_for(name).status(env_lookup: env_lookup)
      end

      def missing_required
        definitions.values.select(&:required?).select do |definition|
          definition.resolve(env_lookup: env_lookup).nil?
        end.map(&:name).sort
      end

      def ready?
        missing_required.empty?
      end

      def to_h
        {
          ready: ready?,
          credentials: names.map { |name| status(name) },
          missing_required: missing_required
        }
      end

      private

      def definition_for(name)
        definitions.fetch(name.to_sym) do
          raise KeyError, "unknown credential #{name.inspect}"
        end
      end
    end
  end
end
