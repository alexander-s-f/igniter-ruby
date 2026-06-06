# frozen_string_literal: true

module Igniter
  module Application
    class ServiceRegistry
      attr_reader :services, :service_definitions, :interfaces

      def initialize(services:, service_definitions:, interfaces:)
        @services = services.each_with_object({}) do |(name, callable), memo|
          memo[name.to_sym] = callable
        end.freeze
        @service_definitions = service_definitions.each_with_object({}) do |(name, definition), memo|
          memo[name.to_sym] = definition
        end.freeze
        @interfaces = interfaces.each_with_object({}) do |(name, definition), memo|
          memo[name.to_sym] = definition
        end.freeze
        freeze
      end

      def fetch(name)
        services.fetch(name.to_sym)
      end

      def service_definition(name)
        service_definitions.fetch(name.to_sym)
      end

      def interface_definition(name)
        interfaces.fetch(name.to_sym)
      end

      def service?(name)
        services.key?(name.to_sym)
      end

      def interface?(name)
        interfaces.key?(name.to_sym)
      end

      def service_names
        services.keys.sort
      end

      def interface_names
        interfaces.keys.sort
      end

      def to_h
        {
          services: service_names,
          interfaces: interface_names,
          definitions: service_definitions.values.map(&:to_h)
        }
      end
    end
  end
end
