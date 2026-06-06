# frozen_string_literal: true

module Igniter
  module Cluster
    class ActiveIncidentSet
      attr_reader :entries, :metadata

      def initialize(entries:, metadata: {})
        @entries = Array(entries).sort_by(&:sequence).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def empty?
        entries.empty?
      end

      def count
        entries.length
      end

      def incident_keys
        entries.map(&:incident_key).freeze
      end

      def incidents
        entries.map(&:incident).freeze
      end

      def to_h
        {
          count: count,
          incident_keys: incident_keys,
          entries: entries.map(&:to_h),
          metadata: metadata.dup
        }
      end
    end
  end
end
