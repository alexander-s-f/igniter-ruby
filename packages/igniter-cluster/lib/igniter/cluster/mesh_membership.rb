# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshMembership
      attr_reader :peers, :allow_degraded, :metadata, :version, :epoch, :events,
                  :source, :snapshot_id, :previous_snapshot_id, :lineage, :feed

      def initialize(peers:, allow_degraded: false, metadata: {}, version: 1, epoch: nil, events: [],
                     source: nil, snapshot_id: nil, previous_snapshot_id: nil, lineage: nil, feed: nil)
        @peers = Array(peers).freeze
        @allow_degraded = allow_degraded == true
        @metadata = metadata.dup.freeze
        @version = Integer(version)
        @epoch = (epoch || "membership/#{@version}").to_s
        @events = Array(events).freeze
        @source = (source || :membership).to_sym
        @feed = feed || MembershipFeed.new(name: @source)
        @snapshot_id = (snapshot_id || "#{@source}/#{@version}").to_s
        @previous_snapshot_id = previous_snapshot_id&.to_s
        @lineage = Array(lineage || [@snapshot_id]).map(&:to_s).freeze
        freeze
      end

      def available_peers
        peers.select do |peer|
          peer.health.available?(allow_degraded: allow_degraded)
        end
      end

      def fetch(name)
        available_peers.find { |peer| peer.name == name.to_sym }
      end

      def include?(name)
        !fetch(name).nil?
      end

      def select(query: nil, names: nil)
        candidates = available_peers
        candidates = candidates.select { |peer| Array(names).map(&:to_sym).include?(peer.name) } unless names.nil?
        return candidates if query.nil?

        candidates.select { |peer| query.matches_peer?(peer) }
      end

      def snapshot
        MembershipSnapshot.new(
          feed: feed,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_snapshot_id,
          version: version,
          epoch: epoch,
          lineage: lineage,
          peer_names: peers.map(&:name),
          available_peer_names: available_peers.map(&:name),
          events: events,
          metadata: metadata
        )
      end

      def snapshot_ref
        snapshot.reference
      end

      def snapshot_delta(previous_membership: nil)
        snapshot.delta(previous_snapshot: previous_membership&.snapshot)
      end

      def to_h
        {
          feed: feed.to_h,
          snapshot: snapshot.to_h,
          source: source,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_snapshot_id,
          lineage: lineage.dup,
          version: version,
          epoch: epoch,
          peer_names: peers.map(&:name),
          available_peer_names: available_peers.map(&:name),
          allow_degraded: allow_degraded,
          events: events.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
