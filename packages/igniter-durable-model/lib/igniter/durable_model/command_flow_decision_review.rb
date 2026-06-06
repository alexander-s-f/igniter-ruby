# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe review read model over persisted command-flow decisions.
    class CommandFlowDecisionReview
      attr_reader :schema_version, :kind, :owner, :filters, :status,
                  :meaning_status, :generated_at, :horizon, :summary,
                  :findings, :decisions, :metadata, :store_fact_exposed,
                  :value_hash_exposed

      def initialize(owner:, filters:, status:, meaning_status:, horizon:,
                     summary:, findings:, decisions:, metadata: {},
                     generated_at: Time.now.utc, schema_version: 1,
                     kind: :command_flow_decision_review,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @filters = normalize_hash(filters).freeze
        @status = token(status)
        @meaning_status = token(meaning_status)
        @generated_at = generated_at
        @horizon = normalize_hash(horizon).freeze
        @summary = normalize_hash(summary).freeze
        @findings = Array(findings).map { |finding| normalize_hash(finding).freeze }.freeze
        @decisions = Array(decisions).map { |decision| normalize_decision(decision).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def ok? = status == :ok

      def warning? = status == :warning

      def critical? = status == :critical

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          owner: owner,
          filters: filters,
          status: status,
          meaning_status: meaning_status,
          generated_at: generated_at,
          horizon: horizon,
          summary: summary,
          findings: findings,
          decisions: decisions,
          metadata: metadata,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def normalize_decision(decision)
        data = decision.respond_to?(:to_h) ? decision.to_h : decision
        normalize_hash(data)
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
