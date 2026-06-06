# frozen_string_literal: true

module Igniter
  module Cluster
    class PlacementDecision
      attr_reader :mode, :candidates, :projection, :projection_report, :metadata, :explanation

      def initialize(mode:, candidates:, projection: nil, projection_report: nil, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @candidates = Array(candidates).freeze
        @projection = projection
        @projection_report = projection_report
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: mode,
          metadata: @metadata
        )
        freeze
      end

      def candidate_names
        candidates.map(&:name)
      end

      def to_h
        {
          mode: mode,
          candidates: candidate_names,
          projection: projection&.to_h,
          projection_report: projection_report&.to_h,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
