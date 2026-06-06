# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshAdmissionResult
      attr_reader :peer_name, :allowed, :code, :metadata, :reason

      def initialize(peer_name:, allowed:, code:, metadata: {}, reason: nil)
        @peer_name = peer_name.to_sym
        @allowed = allowed == true
        @code = code.to_sym
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: @code,
          metadata: @metadata
        )
        freeze
      end

      def allowed?
        allowed
      end

      def denied?
        !allowed?
      end

      def to_h
        {
          peer: peer_name,
          allowed: allowed?,
          code: code,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
