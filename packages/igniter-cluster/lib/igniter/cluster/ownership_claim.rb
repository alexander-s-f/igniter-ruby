# frozen_string_literal: true

module Igniter
  module Cluster
    class OwnershipClaim
      attr_reader :target, :owner, :metadata, :reason

      def initialize(target:, owner:, metadata: {}, reason: nil)
        @target = target.to_s
        @owner = owner
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: :ownership_claim,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          target: target,
          owner: owner.name,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
