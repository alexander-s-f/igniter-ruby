# frozen_string_literal: true

module Igniter
  module Lang
    module Types
      class Descriptor
        attr_reader :kind, :of, :dimensions, :metadata

        def initialize(kind:, of:, dimensions: {}, metadata: {})
          @kind = kind.to_sym
          @of = of
          @dimensions = dimensions.transform_keys(&:to_sym).freeze
          @metadata = metadata.transform_keys(&:to_sym).freeze
          freeze
        end

        def to_h
          {
            kind: kind,
            of: serialize_type(of),
            dimensions: serialize_dimensions,
            metadata: metadata
          }
        end

        def inspect
          "#<#{self.class.name} #{to_h.inspect}>"
        end

        def ==(other)
          other.is_a?(self.class) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end

        private

        def serialize_dimensions
          dimensions.to_h do |name, value|
            [name, serialize_type(value)]
          end
        end

        def serialize_type(value)
          case value
          when Descriptor
            value.to_h
          when Module
            value.name
          else
            value.respond_to?(:to_h) ? value.to_h : value
          end
        end
      end

      class History
        def self.[](of)
          Descriptor.new(kind: :history, of: of)
        end
      end

      class BiHistory
        def self.[](of)
          Descriptor.new(kind: :bi_history, of: of)
        end
      end

      class OLAPPoint
        def self.[](of, dimensions = {})
          Descriptor.new(kind: :olap_point, of: of, dimensions: dimensions)
        end
      end

      class Forecast
        def self.[](of)
          Descriptor.new(kind: :forecast, of: of)
        end
      end
    end
  end
end
