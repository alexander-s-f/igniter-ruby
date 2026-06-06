# frozen_string_literal: true

module Igniter
  module Cluster
    class FailoverStep
      attr_reader :target, :source, :destination, :metadata, :reason

      def initialize(target:, source:, destination:, metadata: {}, reason: nil)
        @target = target.to_s
        @source = source
        @destination = destination
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: :failover_step,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          target: target,
          source: source.name,
          destination: destination.name,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
