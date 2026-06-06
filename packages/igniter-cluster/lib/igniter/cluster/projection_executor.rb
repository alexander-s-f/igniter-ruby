# frozen_string_literal: true

module Igniter
  module Cluster
    class ProjectionExecutor
      attr_reader :metadata

      def initialize(metadata: {})
        @metadata = metadata.dup.freeze
        freeze
      end

      def execute(projection, mode: nil, selected_peer_view: nil, metadata: {})
        resolved_mode = mode || projection.mode

        ProjectionReport.new(
          mode: resolved_mode,
          status: projection.candidate_names.empty? ? :empty : :resolved,
          projection: projection,
          selected_peer_view: selected_peer_view,
          metadata: self.metadata.merge(metadata),
          explanation: DecisionExplanation.new(
            code: :projection_report,
            message: projection_message(resolved_mode, projection, selected_peer_view),
            metadata: {
              candidate_names: projection.candidate_names,
              selected_peer: selected_peer_view&.name
            }
          )
        )
      end

      private

      def projection_message(mode, projection, selected_peer_view)
        return "#{mode} projection resolved #{projection.candidate_names.length} candidate peer(s)" if selected_peer_view.nil?

        "#{mode} projection selected #{selected_peer_view.name} from #{projection.candidate_names.length} candidate peer(s)"
      end
    end
  end
end
