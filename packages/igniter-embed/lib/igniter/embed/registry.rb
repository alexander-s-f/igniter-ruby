# frozen_string_literal: true

module Igniter
  module Embed
    class Registry
      Registration = Struct.new(:name, :definition, :kind, keyword_init: true) do
        def block?
          kind == :block
        end

        def class?
          kind == :class
        end

        def to_h
          {
            name: name,
            kind: kind,
            definition: definition_name
          }
        end

        private

        def definition_name
          return definition.name if definition.respond_to?(:name) && definition.name

          definition.inspect
        end
      end

      def initialize
        @contracts = {}
      end

      def register(name, definition)
        key = normalize_name(name)
        raise DuplicateContractError, "contract #{key} is already registered" if contracts.key?(key)

        contracts[key] = Registration.new(name: key, definition: definition, kind: kind_for(definition))
      end

      def fetch(name)
        key = normalize_name(name)
        contracts.fetch(key)
      rescue KeyError
        raise UnknownContractError, "unknown contract #{key}"
      end

      def key?(name)
        contracts.key?(normalize_name(name))
      end

      def names
        contracts.keys
      end

      def to_h
        contracts.transform_values(&:to_h)
      end

      private

      attr_reader :contracts

      def normalize_name(name)
        name.to_sym
      end

      def kind_for(definition)
        return :class if definition.is_a?(Class) && definition < Igniter::Contract
        return :block if definition.respond_to?(:call)

        raise ArgumentError, "contract definition must be a block or Class < Igniter::Contract"
      end
    end
  end
end
