# frozen_string_literal: true

module Igniter
  module Cluster
    class AdmissionResult
      attr_reader :code, :metadata, :reason

      def initialize(allowed:, code:, metadata: {}, explanation: nil, reason: nil)
        @allowed = allowed == true
        @code = code.to_sym
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason || explanation,
          default_code: @code,
          metadata: @metadata
        )
        freeze
      end

      def self.allowed(code: :allowed, metadata: {}, explanation: nil, reason: nil)
        new(allowed: true, code: code, metadata: metadata, explanation: explanation, reason: reason)
      end

      def self.denied(code: :denied, metadata: {}, explanation: nil, reason: nil)
        new(allowed: false, code: code, metadata: metadata, explanation: explanation, reason: reason)
      end

      def allowed?
        @allowed
      end

      def explanation
        reason&.message
      end

      def to_h
        {
          allowed: allowed?,
          code: code,
          metadata: metadata.dup,
          reason: reason&.to_h,
          explanation: explanation
        }
      end
    end
  end
end
