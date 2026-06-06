# frozen_string_literal: true

module Igniter
  module Cluster
    class MemoryPeerRegistry
      def initialize
        @peers = {}
      end

      def register(peer)
        @peers[peer.name] = peer
        peer
      end

      def fetch(name)
        @peers.fetch(name.to_sym)
      end

      def peers
        @peers.values.sort_by(&:name)
      end
    end
  end
end
