# frozen_string_literal: true

require "time"

module Igniter
  module Application
    class FlowSessionSnapshot
      attr_reader :session_id, :flow_name, :status, :current_step, :pending_inputs,
                  :pending_actions, :events, :artifacts, :metadata, :created_at, :updated_at

      def initialize(session_id:, flow_name:, status: :active, current_step: nil, pending_inputs: [],
                     pending_actions: [], events: [], artifacts: [], metadata: {},
                     created_at: Time.now.utc, updated_at: created_at)
        @session_id = session_id.to_s
        @flow_name = flow_name.to_sym
        @status = status.to_sym
        @current_step = current_step&.to_sym
        @pending_inputs = Array(pending_inputs).map { |entry| PendingInput.from(entry) }.freeze
        @pending_actions = Array(pending_actions).map { |entry| PendingAction.from(entry) }.freeze
        @events = Array(events).map { |entry| FlowEvent.from(entry, session_id: @session_id) }.freeze
        @artifacts = Array(artifacts).map { |entry| ArtifactReference.from(entry) }.freeze
        @metadata = metadata.dup.freeze
        @created_at = normalize_time(created_at)
        @updated_at = normalize_time(updated_at)
        freeze
      end

      def self.from_h(value)
        value = symbolize_keys(value)
        new(
          session_id: value.fetch(:session_id),
          flow_name: value.fetch(:flow_name),
          status: value.fetch(:status),
          current_step: value[:current_step],
          pending_inputs: value.fetch(:pending_inputs, []),
          pending_actions: value.fetch(:pending_actions, []),
          events: value.fetch(:events, []),
          artifacts: value.fetch(:artifacts, []),
          metadata: value.fetch(:metadata, {}),
          created_at: value.fetch(:created_at),
          updated_at: value.fetch(:updated_at)
        )
      end

      def self.from_entry(entry)
        raise ArgumentError, "session #{entry.id.inspect} is not a flow session" unless entry.kind == :flow

        from_h(entry.payload)
      end

      def with_event(event, status: self.status, current_step: self.current_step,
                     pending_inputs: self.pending_inputs, pending_actions: self.pending_actions,
                     artifacts: self.artifacts, metadata: self.metadata,
                     updated_at: Time.now.utc)
        self.class.new(
          session_id: session_id,
          flow_name: flow_name,
          status: status,
          current_step: current_step,
          pending_inputs: pending_inputs,
          pending_actions: pending_actions,
          events: events + [event],
          artifacts: artifacts,
          metadata: metadata,
          created_at: created_at,
          updated_at: updated_at
        )
      end

      def to_h
        {
          session_id: session_id,
          flow_name: flow_name,
          status: status,
          current_step: current_step,
          pending_inputs: pending_inputs.map(&:to_h),
          pending_actions: pending_actions.map(&:to_h),
          events: events.map(&:to_h),
          artifacts: artifacts.map(&:to_h),
          metadata: metadata.dup,
          created_at: created_at.iso8601,
          updated_at: updated_at.iso8601
        }
      end

      private

      def self.symbolize_keys(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end
      private_class_method :symbolize_keys

      def normalize_time(value)
        value.is_a?(String) ? Time.parse(value).utc : value.utc
      end
    end
  end
end
