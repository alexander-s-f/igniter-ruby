# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshMembershipEvent
      attr_reader :version, :type, :peer_name, :metadata, :explanation

      def initialize(version:, type:, peer_name:, metadata: {}, explanation: nil)
        @version = Integer(version)
        @type = type.to_sym
        @peer_name = peer_name.to_sym
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @type,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          version: version,
          type: type,
          peer: peer_name,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
