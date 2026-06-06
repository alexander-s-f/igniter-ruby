# frozen_string_literal: true

module Igniter
  module Application
    class MountIntent
      attr_reader :capsule, :kind, :at, :capabilities, :metadata

      def initialize(capsule:, kind: :generic, at: nil, capabilities: [], metadata: {})
        @capsule = capsule.to_sym
        @kind = kind.to_sym
        @at = normalize_path(at)
        @capabilities = Array(capabilities).map(&:to_sym).sort.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.from(value)
        return value if value.is_a?(self)

        new(**symbolize_keys(value))
      end

      def to_h
        {
          capsule: capsule,
          kind: kind,
          at: at,
          capabilities: capabilities.dup,
          metadata: metadata.dup
        }
      end

      def self.symbolize_keys(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
      private_class_method :symbolize_keys

      private

      def normalize_path(path)
        return nil if path.nil?

        value = path.to_s
        value.start_with?("/") ? value : "/#{value}"
      end
    end
  end
end
