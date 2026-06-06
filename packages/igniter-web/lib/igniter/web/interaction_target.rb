# frozen_string_literal: true

module Igniter
  module Web
    class InteractionTarget
      class << self
        def contract(name)
          new(kind: :contract, name: name)
        end

        def service(name)
          new(kind: :service, name: name)
        end

        def projection(name)
          new(kind: :projection, name: name)
        end
      end

      attr_reader :kind, :name, :metadata

      def initialize(kind:, name:, metadata: {})
        @kind = kind.to_sym
        @name = name.to_s
        @metadata = metadata.freeze
      end

      def to_h
        {
          kind: kind,
          name: name,
          metadata: metadata
        }
      end

      def ==(other)
        other.is_a?(self.class) && other.to_h == to_h
      end
      alias eql? ==

      def hash
        [kind, name, metadata].hash
      end

      def to_s
        "#{kind}:#{name}"
      end
    end
  end
end
