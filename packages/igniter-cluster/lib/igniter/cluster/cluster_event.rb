# frozen_string_literal: true

require "time"

module Igniter
  module Cluster
    class ClusterEvent
      attr_reader :at, :kind, :status, :metadata, :explanation

      def initialize(kind:, status:, at: Time.now.utc, metadata: {}, explanation: nil)
        @at = at.utc
        @kind = kind.to_sym
        @status = status.to_sym
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @kind,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          at: at.iso8601,
          kind: kind,
          status: status,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
