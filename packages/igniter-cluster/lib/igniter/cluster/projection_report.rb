# frozen_string_literal: true

module Igniter
  module Cluster
    class ProjectionReport
      attr_reader :mode, :status, :projection, :selected_peer_view, :metadata, :explanation

      def initialize(mode:, status:, projection:, selected_peer_view: nil, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @status = status.to_sym
        @projection = projection
        @selected_peer_view = selected_peer_view
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @status,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          mode: mode,
          status: status,
          candidate_names: projection.candidate_names,
          stages: projection.stages.map(&:to_h),
          selected_peer_view: selected_peer_view&.to_h,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
