# frozen_string_literal: true

module Igniter
  module Application
    class ServiceDefinition
      attr_reader :name, :callable, :metadata, :source

      def initialize(name:, callable:, metadata: {}, source: :application)
        @name = name.to_sym
        @callable = callable
        @metadata = metadata.dup.freeze
        @source = source.to_sym
        freeze
      end

      def to_h
        {
          name: name,
          source: source,
          metadata: metadata.dup
        }
      end
    end
  end
end
