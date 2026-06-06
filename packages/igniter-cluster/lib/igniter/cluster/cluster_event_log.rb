# frozen_string_literal: true

module Igniter
  module Cluster
    class ClusterEventLog
      attr_reader :events, :metadata

      def initialize(events:, metadata: {})
        @events = Array(events).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def event_count
        events.length
      end

      def to_h
        {
          event_count: event_count,
          events: events.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
