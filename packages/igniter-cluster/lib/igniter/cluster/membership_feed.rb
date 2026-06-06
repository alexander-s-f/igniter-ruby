# frozen_string_literal: true

module Igniter
  module Cluster
    class MembershipFeed
      attr_reader :name, :metadata, :discovery_feed

      def initialize(name:, metadata: {}, discovery_feed: nil)
        @name = name.to_sym
        @metadata = metadata.dup.freeze
        @discovery_feed = discovery_feed || DiscoveryFeed.new(name: @name, metadata: @metadata)
        freeze
      end

      def to_h
        {
          name: name,
          metadata: metadata.dup,
          discovery_feed: discovery_feed.to_h
        }
      end
    end
  end
end
