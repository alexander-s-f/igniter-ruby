# frozen_string_literal: true

module Igniter
  module Cluster
    class ProjectionPolicy
      attr_reader :name, :metadata

      def initialize(name:, metadata: {})
        @name = name.to_sym
        @metadata = metadata.dup.freeze
        freeze
      end

      def project_placement(query:, peers:, placement_policy:)
        stages = []
        current_peers = Array(peers)

        stages << build_stage(:source, peers, current_peers, query: query, metadata: { source: :peer_registry })

        preferred_peers = placement_policy.send(:filter_preferred_peer, query, current_peers)
        stages << build_stage(:preferred_peer, current_peers, preferred_peers, query: query)
        current_peers = preferred_peers

        topology_peers = placement_policy.send(:filter_by_topology, query, current_peers)
        stages << build_stage(:topology, current_peers, topology_peers, query: query)
        current_peers = topology_peers

        capability_peers = placement_policy.send(:filter_by_capabilities, query, current_peers)
        stages << build_stage(:capabilities, current_peers, capability_peers, query: query)
        current_peers = capability_peers

        limited_peers = placement_policy.send(:limit_candidates, current_peers)
        stages << build_stage(:candidate_limit, current_peers, limited_peers, query: query)

        stages.freeze
      end

      def project_mesh(query:, membership:, discovered_peers:, admitted_results:)
        stages = []
        available_peers = membership.available_peers
        discovered = Array(discovered_peers)
        admitted = Array(admitted_results).select(&:allowed?).map { |result| membership.fetch(result.peer_name) }.compact

        stages << build_stage(
          :membership_health,
          membership.peers,
          available_peers,
          query: query,
          metadata: { membership: membership.snapshot_ref }
        )
        stages << build_stage(
          :discovery,
          available_peers,
          discovered,
          query: query,
          metadata: { membership: membership.snapshot_ref }
        )
        stages << build_stage(
          :admission,
          discovered,
          admitted,
          query: query,
          metadata: {
            admitted_peer_names: admitted.map(&:name),
            admission_results: Array(admitted_results).map(&:to_h)
          }
        )
        stages.freeze
      end

      def to_h
        {
          name: name,
          metadata: metadata.dup
        }
      end

      private

      def build_stage(name, input_peers, output_peers, query:, metadata: {})
        input_names = Array(input_peers).map(&:name)
        output_names = Array(output_peers).map(&:name)

        ProjectionStage.new(
          name: name,
          input_peer_names: input_names,
          output_peer_names: output_names,
          metadata: metadata.merge(
            policy: to_h,
            query: query.to_h,
            input_count: input_names.length,
            output_count: output_names.length
          ),
          explanation: DecisionExplanation.new(
            code: :"#{name}_projection",
            message: "#{name} projection kept #{output_names.length} of #{input_names.length} peer(s)",
            metadata: {
              policy: self.name,
              input_peer_names: input_names,
              output_peer_names: output_names
            }
          )
        )
      end
    end
  end
end
