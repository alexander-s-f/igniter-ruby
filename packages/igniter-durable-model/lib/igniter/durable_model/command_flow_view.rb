# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe named operational report over command-flow slices and monitors.
    class CommandFlowView
      attr_reader :schema_version, :kind, :name, :owner, :status, :mode,
                  :horizon, :filters, :action_policy, :slice, :monitor,
                  :summary, :generated_at, :execution_boundary,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(name:, owner:, status:, mode:, horizon:, filters:,
                     action_policy:, slice:, monitor:, summary: nil,
                     generated_at: Time.now.utc, schema_version: 1,
                     kind: :command_flow_view, execution_boundary: :app,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @name = token(name)
        @owner = token(owner)
        @status = token(status)
        @mode = token(mode)
        @horizon = normalize_hash(horizon).freeze
        @filters = normalize_hash(filters).freeze
        @action_policy = normalize_hash(action_policy).freeze
        @slice = slice
        @monitor = monitor
        @summary = normalize_hash(summary || monitor.summary).freeze
        @generated_at = generated_at
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def ok? = status == :ok

      def warning? = status == :warning

      def critical? = status == :critical

      def live? = mode == :live

      def reproducible? = mode == :reproducible

      def pin_required?
        return false unless live?

        %i[mutate execute approve].any? do |action|
          token(action_policy[action]) == :requires_pinned_horizon
        end
      end

      def actionable?(action, capabilities: [])
        decision = action_policy[token(action)]
        return false if decision.nil? || decision == false || token(decision) == :forbidden

        required = Array(action_policy[:required_capabilities]).map { |value| token(value) }
        granted = Array(capabilities).map { |value| token(value) }
        has_caps = (required - granted).empty?

        case token(decision)
        when true then has_caps
        when :requires_capability then has_caps
        when :requires_pinned_horizon then reproducible? && has_caps
        else
          decision == true && has_caps
        end
      end

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          name: name,
          owner: owner,
          status: status,
          mode: mode,
          horizon: horizon,
          filters: filters,
          action_policy: action_policy,
          slice: serialize(slice),
          monitor: serialize(monitor),
          summary: summary,
          generated_at: generated_at,
          execution_boundary: execution_boundary,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def serialize(value)
        return nil if value.nil?
        return normalize_hash(value.to_h) if value.respond_to?(:to_h)

        normalize_value(value)
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
