# frozen_string_literal: true

module Igniter
  module Web
    class FlowInteractionAdapter
      EMPTY_INTERACTIONS = {
        pending_inputs: [],
        pending_actions: [],
        streams: [],
        chats: []
      }.freeze

      attr_reader :interactions, :current_step, :metadata

      def self.pending_state(source, current_step: nil, metadata: {})
        new(source, current_step: current_step, metadata: metadata).pending_state
      end

      def initialize(source, current_step: nil, metadata: {})
        @interactions = normalize_interactions(source)
        @current_step = current_step&.to_sym
        @metadata = metadata.dup.freeze
        freeze
      end

      def pending_state
        {
          pending_inputs: pending_inputs,
          pending_actions: pending_actions
        }
      end

      def pending_inputs
        interactions.fetch(:pending_inputs).map { |entry| pending_input(entry) }.freeze
      end

      def pending_actions
        interactions.fetch(:pending_actions).map { |entry| pending_action(entry) }.freeze
      end

      private

      def normalize_interactions(source)
        raw = if source.respond_to?(:interactions)
                source.interactions
              elsif source.respond_to?(:to_h) && source.to_h.key?(:interactions)
                source.to_h.fetch(:interactions)
              else
                source
              end

        EMPTY_INTERACTIONS.merge(raw || {}).transform_values { |entries| Array(entries).map(&:dup).freeze }.freeze
      end

      def pending_input(entry)
        {
          name: entry.fetch(:name),
          input_type: entry.fetch(:input_type, :text),
          required: entry.fetch(:required, true),
          target: pending_input_target(entry),
          schema: entry.fetch(:schema, {}),
          metadata: adapter_metadata(entry)
        }
      end

      def pending_action(entry)
        {
          name: entry.fetch(:name),
          action_type: entry.fetch(:action_type, :command),
          target: action_target(entry[:target]),
          payload_schema: entry.fetch(:payload_schema, {}),
          metadata: adapter_metadata(entry)
        }
      end

      def pending_input_target(entry)
        current_step || simple_symbol(entry[:target]) || entry.dig(:source, :screen)
      end

      def action_target(value)
        return nil if value.nil?
        return value.fetch(:name).to_s if value.is_a?(Hash) && value.key?(:name)

        value.to_s
      end

      def simple_symbol(value)
        return value if value.is_a?(Symbol)
        return value.to_sym if value.is_a?(String) && value.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

        nil
      end

      def adapter_metadata(entry)
        metadata.merge(
          source: entry[:source],
          role: entry[:role],
          purpose: entry[:purpose],
          web_interaction: entry
        ).compact
      end
    end
  end
end
