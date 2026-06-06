# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-local descriptor for a reusable command-flow operational view.
    class CommandFlowViewDescriptor
      attr_reader :schema_version, :kind, :name, :owner, :filters, :horizon,
                  :mode, :action_policy, :rules, :metadata,
                  :execution_boundary, :store_fact_exposed,
                  :value_hash_exposed

      def initialize(name:, owner:, filters: {}, horizon: {},
                     action_policy: {}, rules: [], metadata: {},
                     schema_version: 1,
                     kind: :command_flow_view_descriptor,
                     execution_boundary: :app, store_fact_exposed: false,
                     value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @name = token(name)
        @owner = token(owner)
        @filters = normalize_hash(filters).freeze
        @horizon = normalize_hash(horizon).freeze
        @mode = token(@horizon[:mode] || :live)
        @action_policy = normalize_hash(action_policy).freeze
        @rules = Array(rules).map { |rule| normalize_hash(rule).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def live? = mode == :live

      def reproducible? = mode == :reproducible

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
          horizon: horizon,
          mode: mode,
          action_policy: action_policy,
          rules: rules,
          metadata: metadata,
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
