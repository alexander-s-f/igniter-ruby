# frozen_string_literal: true

module Igniter
  module Cluster
    class IncidentAction
      attr_reader :id, :sequence, :incident_key, :kind, :status, :actor, :note, :metadata, :explanation

      def self.build_id(incident_key, sequence)
        "incident-action/#{sequence}/#{incident_key}"
      end

      def initialize(incident_key:, sequence:, kind:, status: :recorded, actor: nil, note: nil, metadata: {},
                     explanation: nil)
        @incident_key = incident_key.to_s.freeze
        @sequence = Integer(sequence)
        @id = self.class.build_id(@incident_key, @sequence).freeze
        @kind = kind.to_sym
        @status = status.to_sym
        @actor = actor&.to_sym
        @note = note&.to_s
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: @kind,
          metadata: @metadata
        )
        freeze
      end

      def terminal?
        %i[resolved closed].include?(kind)
      end

      def to_h
        {
          id: id,
          sequence: sequence,
          incident_key: incident_key,
          kind: kind,
          status: status,
          actor: actor,
          note: note,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
