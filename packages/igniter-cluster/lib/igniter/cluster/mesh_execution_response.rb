# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshExecutionResponse
      attr_reader :status, :metadata, :explanation

      def initialize(status:, metadata: {}, explanation: nil)
        @status = status.to_sym
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
          status: status,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
