# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe read model for one command attempt reconstructed from
    # CommandActivity history. It never executes commands or exposes facts.
    class CommandLifecycle
      attr_reader :schema_version, :kind, :status, :owner, :command,
                  :subject_key, :request_id, :actor, :operation, :target,
                  :intent_status, :plan_status, :policy_status,
                  :apply_status, :activity_statuses, :errors, :warnings,
                  :metadata, :latest_activity, :execution_boundary,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(status:, owner:, command:, subject_key: nil,
                     request_id: nil, actor: nil, operation: nil, target: nil,
                     intent_status: nil, plan_status: nil,
                     policy_status: nil, apply_status: nil,
                     activity_statuses: [], errors: [], warnings: [],
                     metadata: {}, latest_activity: nil, schema_version: 1,
                     kind: :command_lifecycle, execution_boundary: :app,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @request_id = request_id
        @actor = actor
        @operation = token(operation)
        @target = normalize_value(target)
        @intent_status = token(intent_status)
        @plan_status = token(plan_status)
        @policy_status = token(policy_status)
        @apply_status = token(apply_status)
        @activity_statuses = Array(activity_statuses).map { |entry| token(entry) }.freeze
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_hash(metadata).freeze
        @latest_activity = normalize_value(latest_activity)
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = !!store_fact_exposed
        @value_hash_exposed = !!value_hash_exposed
        freeze
      end

      def applied? = status == :applied

      def rejected? = status == :rejected || status == :policy_denied

      def review_required? = status == :review_required

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          actor: actor,
          operation: operation,
          target: target,
          intent_status: intent_status,
          plan_status: plan_status,
          policy_status: policy_status,
          apply_status: apply_status,
          activity_statuses: activity_statuses,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          latest_activity: latest_activity,
          execution_boundary: execution_boundary,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
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
