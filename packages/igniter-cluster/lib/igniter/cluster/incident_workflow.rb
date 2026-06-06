# frozen_string_literal: true

module Igniter
  module Cluster
    class IncidentWorkflow
      attr_reader :incident_key, :entries, :actions, :metadata, :explanation

      def initialize(incident_key:, entries:, actions:, metadata: {}, explanation: nil)
        @incident_key = incident_key.to_s.freeze
        @entries = Array(entries).sort_by(&:sequence).freeze
        @actions = Array(actions).sort_by(&:sequence).freeze
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: :incident_workflow,
          metadata: @metadata
        )
        freeze
      end

      def latest_entry
        entries.last
      end

      def latest_action
        actions.last
      end

      def state
        return latest_action.kind if latest_action
        return :active if latest_entry&.active?

        :inactive
      end

      def active?
        return false if %i[resolved closed].include?(state)

        latest_entry&.active? == true
      end

      def action_kinds
        actions.map(&:kind).freeze
      end

      def to_h
        {
          incident_key: incident_key,
          state: state,
          active: active?,
          entry_count: entries.length,
          action_count: actions.length,
          latest_entry: latest_entry&.to_h,
          latest_action: latest_action&.to_h,
          action_kinds: action_kinds,
          entries: entries.map(&:to_h),
          actions: actions.map(&:to_h),
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
