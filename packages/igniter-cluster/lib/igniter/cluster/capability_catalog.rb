# frozen_string_literal: true

module Igniter
  module Cluster
    class CapabilityCatalog
      def initialize(definitions: [])
        @definitions = {}
        Array(definitions).each { |definition| register(definition) }
      end

      def register(definition)
        ensure_mutable!
        normalized = normalize_definition(definition)
        @definitions[normalized.name] = normalized
        self
      end

      def fetch(name)
        @definitions.fetch(name.to_sym)
      end

      def capability?(name)
        @definitions.key?(name.to_sym)
      end

      def resolve(names)
        Array(names).filter_map do |name|
          @definitions[name.to_sym]
        end
      end

      def with_traits(traits)
        required_traits = Array(traits).map(&:to_sym)
        return [] if required_traits.empty?

        definitions.select do |definition|
          required_traits.all? { |trait| definition.traits.include?(trait) }
        end
      end

      def definitions
        @definitions.values.sort_by(&:name)
      end

      def to_h
        {
          definitions: definitions.map(&:to_h)
        }
      end

      private

      def ensure_mutable!
        return unless frozen?

        raise FrozenError, "can't modify frozen capability catalog"
      end

      def normalize_definition(definition)
        return definition if definition.is_a?(CapabilityDefinition)

        CapabilityDefinition.new(**definition)
      end
    end
  end
end
