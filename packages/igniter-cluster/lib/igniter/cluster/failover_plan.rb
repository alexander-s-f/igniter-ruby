# frozen_string_literal: true

module Igniter
  module Cluster
    class FailoverPlan
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

      def source_names
        steps.map { |step| step.source.name }.uniq
      end

      def destination_names
        steps.map { |step| step.destination.name }.uniq
      end

      def targets
        steps.map(&:target).uniq
      end

      def to_h
        {
          mode: mode,
          steps: steps.map(&:to_h),
          source_names: source_names,
          destination_names: destination_names,
          targets: targets,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
