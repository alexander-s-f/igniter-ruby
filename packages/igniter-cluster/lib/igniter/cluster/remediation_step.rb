# frozen_string_literal: true

module Igniter
  module Cluster
    class RemediationStep
      attr_reader :incident_id, :incident_key, :incident_kind, :target, :action,
                  :owner_name, :source_name, :destination_name, :metadata, :reason

      def initialize(incident_id:, incident_key:, incident_kind:, target:, action:, owner_name: nil, source_name: nil,
                     destination_name: nil, metadata: {}, reason: nil)
        @incident_id = incident_id.to_s
        @incident_key = incident_key.to_s
        @incident_kind = incident_kind.to_sym
        @target = target.to_s
        @action = action.to_sym
        @owner_name = owner_name&.to_sym
        @source_name = source_name&.to_sym
        @destination_name = destination_name&.to_sym
        @metadata = metadata.dup.freeze
        @reason = DecisionExplanation.normalize(
          reason,
          default_code: :remediation_step,
          metadata: @metadata
        )
        freeze
      end

      def to_h
        {
          incident_id: incident_id,
          incident_key: incident_key,
          incident_kind: incident_kind,
          target: target,
          action: action,
          owner_name: owner_name,
          source_name: source_name,
          destination_name: destination_name,
          metadata: metadata.dup,
          reason: reason&.to_h
        }
      end
    end
  end
end
