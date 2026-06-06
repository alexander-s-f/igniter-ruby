# frozen_string_literal: true

module Igniter
  module Cluster
    class PeerView
      attr_reader :peer, :query, :included, :metadata

      def initialize(peer:, query:, included:, metadata: {})
        @peer = peer
        @query = query
        @included = included == true
        @metadata = metadata.dup.freeze
        freeze
      end

      def name
        peer.name
      end

      def included?
        included
      end

      def profile
        peer.profile
      end

      def to_h
        {
          peer: peer.name,
          included: included,
          profile: profile.to_h,
          capability_match: query.matches_capabilities?(peer),
          topology_match: query.matches_topology?(peer),
          preferred_peer_match: !query.pinned? || peer.name == query.preferred_peer,
          health: peer.health.to_h,
          metadata: metadata.dup
        }
      end
    end
  end
end
