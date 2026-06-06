# frozen_string_literal: true

module Igniter
  module Application
    class CredentialDefinition
      attr_reader :name, :env, :required, :description, :metadata

      def initialize(name:, env: nil, required: false, description: nil, metadata: {})
        @name = name.to_sym
        @env = env&.to_s
        @required = required == true
        @description = description
        @metadata = symbolize_hash(metadata).freeze
        freeze
      end

      def required?
        required
      end

      def resolve(env_lookup:)
        return nil if env.nil?

        value = env_lookup[env]
        return nil if value.nil? || value.to_s.empty?

        value
      end

      def status(env_lookup:)
        configured = !resolve(env_lookup: env_lookup).nil?
        {
          name: name,
          source: env.nil? ? :unbound : :env,
          env: env,
          required: required?,
          configured: configured,
          missing: !configured,
          redacted: configured ? "[configured]" : nil,
          description: description,
          metadata: metadata.dup
        }.compact
      end

      def to_h
        {
          name: name,
          source: env.nil? ? :unbound : :env,
          env: env,
          required: required?,
          description: description,
          metadata: metadata.dup
        }.compact
      end

      private

      def symbolize_hash(value)
        value.each_with_object({}) do |(key, entry), memo|
          memo[key.to_sym] = entry
        end
      end
    end
  end
end
