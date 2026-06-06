# frozen_string_literal: true

module Igniter
  module Web
    class Record
      class << self
        attr_reader :adapter_definition

        def inherited(subclass)
          super
          subclass.instance_variable_set(:@adapter_definition, adapter_definition)
          subclass.instance_variable_set(:@attribute_definitions, attribute_definitions.dup)
        end

        def adapter(name = nil, **options)
          return @adapter_definition if name.nil?

          @adapter_definition = {
            name: name.to_sym,
            options: options.freeze
          }.freeze
        end

        def attribute(name, type = :any, **options)
          definition = {
            name: name.to_sym,
            type: type.to_sym,
            options: options.freeze
          }.freeze

          @attribute_definitions = attribute_definitions + [definition]
        end

        def attribute_definitions
          @attribute_definitions ||= []
        end
      end

      attr_reader :attributes

      def initialize(**attributes)
        @attributes = attributes.transform_keys(&:to_sym).freeze
      end

      def [](name)
        attributes[name.to_sym]
      end

      def to_h
        attributes.dup
      end
    end
  end
end
