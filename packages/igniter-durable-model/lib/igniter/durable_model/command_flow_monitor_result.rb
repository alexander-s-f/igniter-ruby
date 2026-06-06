# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe monitor evaluation over a CommandFlowSlice.
    class CommandFlowMonitorResult
      attr_reader :schema_version, :kind, :name, :owner, :filters, :since,
                  :as_of, :generated_at, :status, :rules, :observations,
                  :alerts, :summary, :slice, :execution_boundary,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(owner:, filters:, summary:, slice:, rules: [],
                     observations: [], alerts: [], name: nil, since: nil,
                     as_of: nil, generated_at: Time.now.utc, status: :ok,
                     schema_version: 1, kind: :command_flow_monitor_result,
                     execution_boundary: :app, store_fact_exposed: false,
                     value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @name = name.nil? ? nil : token(name)
        @owner = token(owner)
        @filters = normalize_hash(filters).freeze
        @since = since
        @as_of = as_of
        @generated_at = generated_at
        @status = token(status)
        @rules = Array(rules).map { |rule| normalize_hash(rule).freeze }.freeze
        @observations = Array(observations).map { |entry| normalize_hash(entry).freeze }.freeze
        @alerts = Array(alerts).map { |entry| normalize_hash(entry).freeze }.freeze
        @summary = normalize_hash(summary).freeze
        @slice = normalize_value(slice)
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = !!store_fact_exposed
        @value_hash_exposed = !!value_hash_exposed
        freeze
      end

      def ok? = status == :ok

      def warning? = status == :warning

      def critical? = status == :critical

      def triggered? = alerts.any?

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          name: name,
          owner: owner,
          filters: filters,
          since: since,
          as_of: as_of,
          generated_at: generated_at,
          status: status,
          rules: rules,
          observations: observations,
          alerts: alerts,
          summary: summary,
          slice: slice,
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
          return normalize_hash(value.to_h) if value.respond_to?(:to_h)

          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
