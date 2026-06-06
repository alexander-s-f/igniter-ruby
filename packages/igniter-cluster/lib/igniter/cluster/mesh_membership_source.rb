# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshMembershipSource
      attr_reader :name, :metadata, :feed

      def initialize(name: :memory, metadata: {})
        @name = name.to_sym
        @metadata = metadata.dup.freeze
        @feed = MembershipFeed.new(name: @name, metadata: @metadata)
        freeze
      end

      def call(environment:, allow_degraded:, metadata: {}, previous_membership: nil)
        version = previous_membership&.version || 1
        snapshot_id = next_snapshot_id(version: version)

        MeshMembership.new(
          peers: environment.peers,
          allow_degraded: allow_degraded,
          metadata: self.metadata.merge(metadata),
          version: version,
          epoch: previous_membership&.epoch,
          events: [],
          source: name,
          snapshot_id: snapshot_id,
          previous_snapshot_id: previous_membership&.snapshot_id,
          lineage: next_lineage(previous_membership: previous_membership, snapshot_id: snapshot_id),
          feed: feed
        )
      end

      def to_h
        feed.to_h
      end

      private

      def next_snapshot_id(version:)
        "#{name}/#{version}"
      end

      def next_lineage(previous_membership:, snapshot_id:)
        Array(previous_membership&.lineage) + [snapshot_id]
      end
    end
  end
end
