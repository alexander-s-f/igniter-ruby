# frozen_string_literal: true

module Igniter
  module Cluster
    class MembershipDelta
      attr_reader :feed, :from_snapshot_ref, :to_snapshot_ref, :joined_peer_names,
                  :left_peer_names, :updated_peer_names, :events, :metadata

      def initialize(feed:, to_snapshot_ref:, from_snapshot_ref: nil, joined_peer_names: [],
                     left_peer_names: [], updated_peer_names: [], events: [], metadata: {})
        @feed = feed
        @from_snapshot_ref = from_snapshot_ref&.dup&.freeze
        @to_snapshot_ref = to_snapshot_ref.dup.freeze
        @joined_peer_names = Array(joined_peer_names).map(&:to_sym).freeze
        @left_peer_names = Array(left_peer_names).map(&:to_sym).freeze
        @updated_peer_names = Array(updated_peer_names).map(&:to_sym).freeze
        @events = Array(events).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          feed: feed.to_h,
          from_snapshot_ref: from_snapshot_ref&.dup,
          to_snapshot_ref: to_snapshot_ref.dup,
          joined_peer_names: joined_peer_names.dup,
          left_peer_names: left_peer_names.dup,
          updated_peer_names: updated_peer_names.dup,
          events: events.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
