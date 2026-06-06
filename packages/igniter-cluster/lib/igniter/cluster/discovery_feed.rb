# frozen_string_literal: true

module Igniter
  module Cluster
    class DiscoveryFeed
      attr_reader :name, :metadata

      def initialize(name:, metadata: {})
        @name = name.to_sym
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          name: name,
          metadata: metadata.dup
        }
      end
    end
  end
end
