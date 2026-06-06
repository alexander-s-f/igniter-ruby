# frozen_string_literal: true

require "time"

module Igniter
  module Cluster
    class LeaseGrant
      attr_reader :target, :owner, :ttl_seconds, :renewable, :issued_at, :expires_at, :metadata, :reason

      def initialize(target:, owner:, ttl_seconds:, renewable:, issued_at:, expires_at:, metadata: {}, reason: nil)
        @target = target.to_s
        @owner = owner
        @ttl_seconds = Integer(ttl_seconds)
        @renewable = renewable == true
        @issued_at = issued_at
        @expires_at = expires_at
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: :lease_grant,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          target: target,
          owner: owner.name,
          ttl_seconds: ttl_seconds,
          renewable: renewable,
          issued_at: issued_at.iso8601,
          expires_at: expires_at.iso8601,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
