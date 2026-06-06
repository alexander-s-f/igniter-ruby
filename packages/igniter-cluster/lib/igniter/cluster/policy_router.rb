# frozen_string_literal: true

module Igniter
  module Cluster
    class PolicyRouter
      attr_reader :policy

      def initialize(policy:)
        @policy = policy
        @projection_executor = ProjectionExecutor.new(metadata: { scope: :route })
        freeze
      end

      def route(request:, placement:)
        candidates = placement.candidates
        raise RoutingError, "no peers available for #{request.session_id}" if candidates.empty?

        selected_peer = policy.select_peer(query: request.query, candidates: candidates)
        raise RoutingError, missing_route_message(request) if selected_peer.nil?

        selected_peer_view = placement.projection&.candidate_views&.find { |view| view.peer == selected_peer }

        Route.new(
          peer: selected_peer,
          peer_view: selected_peer_view,
          projection_report: projection_executor.execute(
            placement.projection,
            mode: policy.route_mode_for(request.query),
            selected_peer_view: selected_peer_view,
            metadata: { policy: policy.to_h }
          ),
          mode: policy.route_mode_for(request.query),
          metadata: route_metadata(request, placement, candidates, selected_peer, selected_peer_view),
          explanation: policy.explanation_for(query: request.query, peer: selected_peer)
        )
      end

      private

      attr_reader :projection_executor

      def route_metadata(request, placement, candidates, selected_peer, selected_peer_view)
        {
          policy: policy.to_h,
          query: request.query.to_h,
          candidate_names: candidates.map(&:name),
          membership_projection: placement.projection&.to_h,
          projection_report: placement.projection_report&.to_h,
          route_projection_report: projection_executor.execute(
            placement.projection,
            mode: policy.route_mode_for(request.query),
            selected_peer_view: selected_peer_view,
            metadata: { policy: policy.to_h }
          ).to_h,
          selected_peer_view: selected_peer_view&.to_h,
          selected_capabilities: selected_peer.capabilities,
          selected_peer_profile: selected_peer.profile.to_h
        }
      end

      def missing_route_message(request)
        [
          "no route for #{request.session_id}",
          "query=#{request.query.to_h.inspect}",
          "policy=#{policy.to_h.inspect}"
        ].join(" ")
      end
    end
  end
end
