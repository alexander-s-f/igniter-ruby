# frozen_string_literal: true

module Igniter
  module Cluster
    class DecisionExplanation
      attr_reader :code, :message, :metadata

      def initialize(code:, message:, metadata: {})
        @code = code.to_sym
        @message = message.to_s
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.normalize(value, default_code:, metadata: {})
        return value if value.is_a?(self)
        return nil if value.nil?

        new(code: default_code, message: value, metadata: metadata)
      end

      def to_h
        {
          code: code,
          message: message,
          metadata: metadata.dup
        }
      end
    end
  end
end
