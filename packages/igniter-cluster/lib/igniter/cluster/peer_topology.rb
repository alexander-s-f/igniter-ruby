# frozen_string_literal: true

module Igniter
  module Cluster
    class PeerTopology
      attr_reader :region, :zone, :labels, :metadata

      def initialize(region: nil, zone: nil, labels: {}, metadata: {})
        @region = region&.to_s
        @zone = zone&.to_s
        @labels = normalize_labels(labels)
        @metadata = metadata.dup.freeze
        freeze
      end

      def label(name)
        labels[name.to_sym]
      end

      def tagged?(name, value = nil)
        return labels.key?(name.to_sym) if value.nil?

        label(name) == value
      end

      def matches_labels?(required_labels)
        required_labels.all? do |key, value|
          tagged?(key, value)
        end
      end

      def matches_region?(preferred_region)
        return true if preferred_region.nil?

        region == preferred_region.to_s
      end

      def matches_zone?(preferred_zone)
        return true if preferred_zone.nil?

        zone == preferred_zone.to_s
      end

      def to_h
        {
          region: region,
          zone: zone,
          labels: labels.dup,
          metadata: metadata.dup
        }
      end

      private

      def normalize_labels(labels)
        labels.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end
    end
  end
end
