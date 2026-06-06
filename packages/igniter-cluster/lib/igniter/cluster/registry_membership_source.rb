# frozen_string_literal: true

module Igniter
  module Cluster
    class RegistryMembershipSource < MeshMembershipSource
      def initialize(metadata: {})
        super(name: :registry, metadata: metadata)
      end

      def call(environment:, allow_degraded:, metadata: {}, previous_membership: nil)
        signatures = peer_signatures(environment.peers)
        previous_signatures = peer_signatures(previous_membership&.peers)
        changed = previous_signatures != signatures
        version = next_version(previous_membership: previous_membership, changed: changed)
        snapshot_id = next_snapshot_id(version: version)
        events = build_events(
          previous_signatures: previous_signatures,
          current_signatures: signatures,
          version: version,
          initial_snapshot: previous_membership.nil?
        )

        MeshMembership.new(
          peers: environment.peers,
          allow_degraded: allow_degraded,
          metadata: self.metadata.merge(metadata),
          version: version,
          epoch: "registry/#{version}",
          events: events,
          source: name,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_membership&.snapshot_id,
          lineage: next_lineage(previous_membership: previous_membership, snapshot_id: snapshot_id),
          feed: feed
        )
      end

      private

      def next_version(previous_membership:, changed:)
        previous_version = previous_membership&.version.to_i
        return 1 if previous_version.zero?
        return previous_version + 1 if changed

        previous_version
      end

      def peer_signatures(peers)
        Array(peers).each_with_object({}) do |peer, memo|
          memo[peer.name] = peer.to_h
        end
      end

      def build_events(previous_signatures:, current_signatures:, version:, initial_snapshot:)
        return [].freeze if initial_snapshot

        events = []
        previous_names = previous_signatures.keys
        current_names = current_signatures.keys

        (current_names - previous_names).each do |peer_name|
          events << MeshMembershipEvent.new(
            version: version,
            type: :peer_joined,
            peer_name: peer_name,
            metadata: { peer: current_signatures.fetch(peer_name) }
          )
        end

        (previous_names - current_names).each do |peer_name|
          events << MeshMembershipEvent.new(
            version: version,
            type: :peer_left,
            peer_name: peer_name,
            metadata: { peer: previous_signatures.fetch(peer_name) }
          )
        end

        (previous_names & current_names).each do |peer_name|
          next if previous_signatures.fetch(peer_name) == current_signatures.fetch(peer_name)

          events << MeshMembershipEvent.new(
            version: version,
            type: :peer_updated,
            peer_name: peer_name,
            metadata: {
              previous: previous_signatures.fetch(peer_name),
              current: current_signatures.fetch(peer_name)
            }
          )
        end

        events.freeze
      end
    end
  end
end
