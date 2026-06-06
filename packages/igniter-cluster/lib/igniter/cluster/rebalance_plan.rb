# frozen_string_literal: true

module Igniter
  module Cluster
    class RebalancePlan
      attr_reader :mode, :moves, :metadata, :explanation

      def initialize(mode:, moves:, metadata: {}, explanation: nil)
        @mode = mode.to_sym
        @moves = Array(moves).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @mode,
          metadata: @metadata
        )
        freeze
      end

      def source_names
        moves.map { |move| move.source.name }.uniq
      end

      def destination_names
        moves.map { |move| move.destination.name }.uniq
      end

      def to_h
        {
          mode: mode,
          moves: moves.map(&:to_h),
          source_names: source_names,
          destination_names: destination_names,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
