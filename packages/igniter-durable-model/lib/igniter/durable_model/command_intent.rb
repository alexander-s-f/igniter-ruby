# frozen_string_literal: true

module Igniter
  module DurableModel
    # Pure command boundary object. It describes app-owned intent and never
    # executes, writes, appends, publishes, or calls callbacks.
    class CommandIntent
      attr_reader :schema_version, :kind, :owner, :command, :subject_key,
                  :operation, :target_shape, :effect, :boundary, :changes,
                  :event, :params, :metadata, :execution_allowed

      def initialize(owner:, command:, operation:, target_shape:, effect: {},
                     subject_key: nil, boundary: :app, changes: {}, event: nil,
                     params: {}, metadata: {}, schema_version: 1,
                     kind: :command_intent, execution_allowed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @operation = token(operation)
        @target_shape = token(target_shape)
        @effect = normalize_hash(effect).freeze
        @boundary = token(boundary || :app)
        @changes = normalize_hash(changes).freeze
        @event = event.nil? ? nil : normalize_value(event)
        @params = normalize_hash(params).freeze
        @metadata = normalize_hash(metadata).freeze
        @execution_allowed = !!execution_allowed
        freeze
      end

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          owner: owner,
          command: command,
          subject_key: subject_key,
          operation: operation,
          target_shape: target_shape,
          effect: effect,
          boundary: boundary,
          changes: changes,
          event: event,
          params: params,
          metadata: metadata,
          execution_allowed: execution_allowed
        }.compact
      end

      def to_activity_event
        {
          kind: :command_intent,
          owner: owner,
          command: command,
          subject_key: subject_key,
          operation: operation,
          boundary: boundary,
          status: :intended
        }.compact.freeze
      end

      private

      def normalize_hash(value)
        return {} if value.nil?
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, entry), acc|
          acc[token(key)] = normalize_value(entry)
        end
      end

      def normalize_value(value)
        case value
        when Hash
          normalize_hash(value).freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
