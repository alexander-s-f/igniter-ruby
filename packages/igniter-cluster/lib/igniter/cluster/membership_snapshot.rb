# frozen_string_literal: true

module Igniter
  module Cluster
    class MembershipSnapshot
      attr_reader :feed, :snapshot_id, :previous_snapshot_id, :version, :epoch,
                  :lineage, :peer_names, :available_peer_names, :events, :metadata

      def initialize(feed:, snapshot_id:, version:, epoch:, lineage:, peer_names:, available_peer_names:,
                     previous_snapshot_id: nil, events: [], metadata: {})
        @feed = feed
        @snapshot_id = snapshot_id.to_s
        @previous_snapshot_id = previous_snapshot_id&.to_s
        @version = Integer(version)
        @epoch = epoch.to_s
        @lineage = Array(lineage).map(&:to_s).freeze
        @peer_names = Array(peer_names).map(&:to_sym).freeze
        @available_peer_names = Array(available_peer_names).map(&:to_sym).freeze
        @events = Array(events).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def reference
        {
          feed: feed.to_h,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_snapshot_id,
          version: version,
          epoch: epoch,
          lineage: lineage.dup
        }
      end

      def to_h
        reference.merge(
          peer_names: peer_names.dup,
          available_peer_names: available_peer_names.dup,
          events: events.map(&:to_h),
          metadata: metadata.dup
        )
      end

      def delta(previous_snapshot: nil)
        MembershipDelta.new(
          feed: feed,
          from_snapshot_ref: previous_snapshot&.reference,
          to_snapshot_ref: reference,
          joined_peer_names: peer_names_for(:peer_joined),
          left_peer_names: peer_names_for(:peer_left),
          updated_peer_names: peer_names_for(:peer_updated),
          events: events,
          metadata: metadata
        )
      end

      private

      def peer_names_for(type)
        events.select { |event| event.type == type }.map(&:peer_name)
      end
    end
  end
end
