# frozen_string_literal: true

module Igniter
  module Cluster
    class ProjectionStage
      attr_reader :name, :input_peer_names, :output_peer_names, :metadata, :explanation

      def initialize(name:, input_peer_names:, output_peer_names:, metadata: {}, explanation: nil)
        @name = name.to_sym
        @input_peer_names = Array(input_peer_names).map(&:to_sym).freeze
        @output_peer_names = Array(output_peer_names).map(&:to_sym).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @name,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          name: name,
          input_peer_names: input_peer_names.dup,
          output_peer_names: output_peer_names.dup,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
