# frozen_string_literal: true

module Igniter
  module DurableModel
    # Transparent app-owned orchestration summary for one command attempt.
    # It stitches existing command objects together without becoming an executor.
    class CommandFlow
      attr_reader :schema_version, :kind, :status, :mode, :owner, :command,
                  :subject_key, :request_id, :actor, :intent, :plan,
                  :activity_event, :policy_decision, :apply_receipt,
                  :lifecycle, :errors, :warnings, :metadata,
                  :execution_boundary, :store_fact_exposed,
                  :value_hash_exposed

      def initialize(status:, mode:, owner:, command:, subject_key: nil,
                     request_id: nil, actor: nil, intent: nil, plan: nil,
                     activity_event: nil, policy_decision: nil,
                     apply_receipt: nil, lifecycle: nil, errors: [],
                     warnings: [], metadata: {}, schema_version: 1,
                     kind: :command_flow, execution_boundary: :app,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @mode = token(mode)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @request_id = request_id
        @actor = actor
        @intent = intent
        @plan = plan
        @activity_event = activity_event
        @policy_decision = policy_decision
        @apply_receipt = apply_receipt
        @lifecycle = lifecycle
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_hash(metadata).freeze
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = !!store_fact_exposed
        @value_hash_exposed = !!value_hash_exposed
        freeze
      end

      def applied? = status == :applied

      def rejected? = %i[policy_denied rejected].include?(status)

      def review_required? = status == :review_required

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          mode: mode,
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          actor: actor,
          intent: serialize(intent),
          plan: serialize_plan(plan),
          activity_event: serialize(activity_event),
          policy_decision: serialize(policy_decision),
          apply_receipt: serialize(apply_receipt),
          lifecycle: serialize(lifecycle),
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          execution_boundary: execution_boundary,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def serialize(value)
        return nil if value.nil?
        return normalize_value(value.to_h) if value.respond_to?(:to_h)

        normalize_value(value)
      end

      def serialize_plan(value)
        data = serialize(value)
        return data unless data.is_a?(Hash)

        data.reject { |key, _entry| key == :value }
      end

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
