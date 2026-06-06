# frozen_string_literal: true

module Igniter
  module Cluster
    class MembershipProjection
      attr_reader :mode, :query, :peer_views, :candidate_views, :stages, :metadata, :explanation

      def initialize(mode:, query:, peer_views:, candidate_views:, stages: [], metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @query = query
        @peer_views = Array(peer_views).freeze
        @candidate_views = Array(candidate_views).freeze
        @stages = Array(stages).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @mode,
          metadata: @metadata
        )
        freeze
      end

      def candidates
        candidate_views.map(&:peer).freeze
      end

      def candidate_names
        candidates.map(&:name)
      end

      def to_h
        {
          mode: mode,
          query: query.to_h,
          peer_views: peer_views.map(&:to_h),
          candidate_views: candidate_views.map(&:to_h),
          candidate_names: candidate_names,
          stages: stages.map(&:to_h),
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
