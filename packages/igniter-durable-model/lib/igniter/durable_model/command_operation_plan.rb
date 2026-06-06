# frozen_string_literal: true

module Igniter
  module DurableModel
    # Dry-run preview of how an app boundary could apply a CommandIntent.
    # Plans are data only: no writes, appends, callbacks, or protocol dispatch.
    class CommandOperationPlan
      attr_reader :schema_version, :kind, :owner, :command, :subject_key,
                  :operation, :status, :target, :value, :event, :effect,
                  :errors, :warnings, :metadata, :execution_allowed

      def initialize(owner:, command:, operation:, status:, subject_key: nil,
                     target: nil, value: nil, event: nil, effect: {},
                     errors: [], warnings: [], metadata: {},
                     schema_version: 1, kind: :command_operation_plan,
                     execution_allowed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @operation = token(operation)
        @status = token(status)
        @target = normalize_value(target)
        @value = normalize_value(value)
        @event = normalize_value(event)
        @effect = normalize_hash(effect).freeze
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_hash(metadata).freeze
        @execution_allowed = !!execution_allowed
        freeze
      end

      def ready? = status == :ready

      def invalid? = status == :invalid

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
          status: status,
          target: target,
          value: value,
          event: event,
          effect: effect,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          execution_allowed: execution_allowed
        }.compact
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
