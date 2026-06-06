# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-facing activity summary for command intents and operation plans.
    # It intentionally omits fact ids, value hashes, and planned record values.
    class CommandActivityEvent
      attr_reader :schema_version, :kind, :owner, :command, :subject_key,
                  :operation, :status, :intent_status, :plan_status, :target,
                  :errors, :warnings, :metadata, :store_fact_exposed,
                  :value_hash_exposed, :execution_allowed

      def initialize(owner:, command:, operation:, status:, subject_key: nil,
                     intent_status: :ready, plan_status: nil, target: nil,
                     errors: [], warnings: [], metadata: {},
                     schema_version: 1, kind: :command_activity_event,
                     store_fact_exposed: false, value_hash_exposed: false,
                     execution_allowed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @operation = token(operation)
        @status = token(status)
        @intent_status = token(intent_status)
        @plan_status = token(plan_status)
        @target = normalize_value(target)
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_hash(metadata).freeze
        @store_fact_exposed = !!store_fact_exposed
        @value_hash_exposed = !!value_hash_exposed
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
          status: status,
          intent_status: intent_status,
          plan_status: plan_status,
          target: target,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed,
          execution_allowed: execution_allowed
        }
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
