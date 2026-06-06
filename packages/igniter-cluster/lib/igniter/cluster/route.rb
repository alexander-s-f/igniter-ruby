# frozen_string_literal: true

module Igniter
  module Cluster
    class Route
      attr_reader :peer, :peer_view, :projection_report, :mode, :metadata, :explanation

      def initialize(peer:, mode:, peer_view: nil, projection_report: nil, metadata: {}, explanation: nil)
        @peer = peer
        @peer_view = peer_view
        @projection_report = projection_report
        @mode = mode.to_sym
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: mode,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          peer: peer.name,
          peer_view: peer_view&.to_h,
          projection_report: projection_report&.to_h,
          mode: mode,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
