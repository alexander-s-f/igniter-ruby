# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshExecutionTrace
      attr_reader :trace_id, :plan_kind, :attempts, :metadata, :explanation

      def initialize(trace_id:, plan_kind:, attempts:, metadata: {}, explanation: nil)
        @trace_id = trace_id.to_s
        @plan_kind = plan_kind.to_sym
        @attempts = Array(attempts).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @plan_kind,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          trace_id: trace_id,
          plan_kind: plan_kind,
          attempts: attempts.map(&:to_h),
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
