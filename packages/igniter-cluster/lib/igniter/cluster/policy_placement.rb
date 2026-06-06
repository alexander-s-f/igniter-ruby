# frozen_string_literal: true

module Igniter
  module Cluster
    class PolicyPlacement
      attr_reader :policy, :projection_policy, :projection_executor

      def initialize(policy:)
        @policy = policy
        @projection_policy = ProjectionPolicy.new(name: :"placement_#{policy.name}")
        @projection_executor = ProjectionExecutor.new(metadata: { scope: :placement })
        freeze
      end

      def place(request:, peers:)
        projection = build_projection(request: request, peers: peers)
        selected_peers = projection.candidates
        PlacementDecision.new(
          mode: policy.mode_for(request.query),
          candidates: selected_peers,
          projection: projection,
          projection_report: projection_executor.execute(projection, metadata: { policy: policy.to_h }),
          metadata: {
            policy: policy.to_h,
            projection_policy: projection_policy.to_h,
            query: request.query.to_h,
            membership_projection: projection.to_h,
            candidate_peer_views: projection.candidate_views.map(&:to_h),
            candidate_profiles: selected_peers.map { |peer| peer.profile.to_h }
          },
          explanation: policy.explanation_for(query: request.query, candidates: selected_peers)
        )
      end

      private

      def build_projection(request:, peers:)
        selected_peers = policy.select_candidates(query: request.query, peers: peers)
        stages = projection_policy.project_placement(query: request.query, peers: peers, placement_policy: policy)
        peer_views = Array(peers).map do |peer|
          PeerView.new(
            peer: peer,
            query: request.query,
            included: selected_peers.include?(peer),
            metadata: {
              source: :peer_registry,
              policy: policy.to_h
            }
          )
        end
        candidate_views = peer_views.select(&:included?)

        MembershipProjection.new(
          mode: policy.mode_for(request.query),
          query: request.query,
          peer_views: peer_views,
          candidate_views: candidate_views,
          stages: stages,
          metadata: {
            source: :peer_registry,
            policy: policy.to_h,
            projection_policy: projection_policy.to_h
          },
          explanation: policy.explanation_for(query: request.query, candidates: selected_peers)
        )
      end
    end
  end
end
