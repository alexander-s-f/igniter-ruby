# frozen_string_literal: true

module Igniter
  module Cluster
    class OwnershipPlan
      attr_reader :mode, :claims, :metadata, :explanation

      def initialize(mode:, claims:, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @claims = Array(claims).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @mode,
          metadata: @metadata
        )
        freeze
      end

      def owner_names
        claims.map { |claim| claim.owner.name }.uniq
      end

      def targets
        claims.map(&:target).uniq
      end

      def to_h
        {
          mode: mode,
          claims: claims.map(&:to_h),
          owner_names: owner_names,
          targets: targets,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
