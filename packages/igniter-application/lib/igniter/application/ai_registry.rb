# frozen_string_literal: true

module Igniter
  module Application
    class AIRegistry
      attr_reader :definitions, :credentials

      def initialize(definitions:, credentials:)
        @definitions = definitions.each_with_object({}) do |definition, memo|
          memo[definition.name] = definition
        end.freeze
        @credentials = credentials
        @clients = {}
      end

      def client(name = :default)
        key = name.to_sym
        @clients[key] ||= definitions.fetch(key).build_client(credentials: credentials)
      end

      def definition(name = :default)
        definitions.fetch(name.to_sym)
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
