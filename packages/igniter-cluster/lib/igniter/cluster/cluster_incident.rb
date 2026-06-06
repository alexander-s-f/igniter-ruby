# frozen_string_literal: true

module Igniter
  module Cluster
    class ClusterIncident
      attr_reader :kind, :status, :severity, :targets, :source_names, :destination_names,
                  :owner_names, :metadata, :explanation

      def initialize(kind:, status:, severity:, targets: [], source_names: [], destination_names: [], owner_names: [],
                     metadata: {}, explanation: nil)
        @kind = kind.to_sym
        @status = status.to_sym
        @severity = severity.to_sym
        @targets = Array(targets).map(&:to_s).freeze
        @source_names = Array(source_names).map(&:to_sym).freeze
        @destination_names = Array(destination_names).map(&:to_sym).freeze
        @owner_names = Array(owner_names).map(&:to_sym).freeze
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
          kind: kind,
          status: status,
          severity: severity,
          targets: targets.dup,
          source_names: source_names.dup,
          destination_names: destination_names.dup,
          owner_names: owner_names.dup,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
