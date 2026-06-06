# frozen_string_literal: true

module Igniter
  module Cluster
    class OperatorTimeline
      attr_reader :kind, :status, :event_log, :metadata, :explanation

      def initialize(kind:, status:, event_log:, metadata: {}, explanation: nil)
        @kind = kind.to_sym
        @status = status.to_sym
        @event_log = event_log
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @status,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          kind: kind,
          status: status,
          event_count: event_log.event_count,
          event_log: event_log.to_h,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
