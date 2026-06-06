# frozen_string_literal: true

module Igniter
  module Cluster
    class RebalanceMove
      attr_reader :source, :destination, :metadata, :reason

      def initialize(source:, destination:, metadata: {}, reason: nil)
        @source = source
        @destination = destination
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: :rebalance_move,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          source: source.name,
          destination: destination.name,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
