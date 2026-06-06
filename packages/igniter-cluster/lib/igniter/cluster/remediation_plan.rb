# frozen_string_literal: true

module Igniter
  module Cluster
    class RemediationPlan
      attr_reader :mode, :steps, :metadata, :explanation

      def initialize(mode:, steps:, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @steps = Array(steps).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @mode,
          metadata: @metadata
        )
        freeze
      end

      def targets
        steps.map(&:target).uniq
      end

      def incident_ids
        steps.map(&:incident_id).uniq
      end

      def action_kinds
        steps.map(&:action).uniq
      end

      def to_h
        {
          mode: mode,
          steps: steps.map(&:to_h),
          targets: targets,
          incident_ids: incident_ids,
          action_kinds: action_kinds,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
