# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class Operation
        attr_reader :kind, :name, :attributes

        def initialize(kind:, name:, attributes: {})
          @kind = kind.to_sym
          @name = name.to_sym
          @attributes = attributes.transform_keys(&:to_sym).freeze
          freeze
        end

        def attribute(key)
          attributes.fetch(key.to_sym)
        end

        def attribute?(key)
          attributes.key?(key.to_sym)
        end

        def with_attributes(updated_attributes)
          self.class.new(kind: kind, name: name, attributes: updated_attributes)
        end

        def output?
          kind == :output
        end

        def to_h
          {
            kind: kind,
            name: name,
            attributes: StructuredDump.dump(attributes)
          }
        end
      end
    end
  end
end
