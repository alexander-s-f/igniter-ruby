# frozen_string_literal: true

module Igniter
  module Cluster
    class LeasePlan
      attr_reader :mode, :grants, :metadata, :explanation

      def initialize(mode:, grants:, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @grants = Array(grants).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @mode,
          metadata: @metadata
        )
        freeze
      end

      def owner_names
        grants.map { |grant| grant.owner.name }.uniq
      end

      def targets
        grants.map(&:target).uniq
      end

      def to_h
        {
          mode: mode,
          grants: grants.map(&:to_h),
          owner_names: owner_names,
          targets: targets,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
