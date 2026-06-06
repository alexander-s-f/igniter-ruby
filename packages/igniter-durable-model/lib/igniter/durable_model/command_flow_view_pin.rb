# frozen_string_literal: true

module Igniter
  module DurableModel
    # App-safe decision evidence produced by pinning a command-flow view.
    class CommandFlowViewPin
      attr_reader :schema_version, :kind, :status, :meaning_status, :name,
                  :owner, :action, :actor, :capabilities,
                  :missing_capabilities, :horizon, :view, :receipt, :errors,
                  :warnings, :metadata, :generated_at, :execution_boundary,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(status:, meaning_status:, name:, owner:, action:,
                     actor: nil, capabilities: [], missing_capabilities: [],
                     horizon: {}, view: nil, receipt: {}, errors: [],
                     warnings: [], metadata: {}, generated_at: Time.now.utc,
                     schema_version: 1, kind: :command_flow_view_pin,
                     execution_boundary: :app, store_fact_exposed: false,
                     value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @meaning_status = token(meaning_status)
        @name = token(name)
        @owner = token(owner)
        @action = token(action)
        @actor = actor
        @capabilities = Array(capabilities).map { |value| token(value) }.freeze
        @missing_capabilities = Array(missing_capabilities).map { |value| token(value) }.freeze
        @horizon = normalize_hash(horizon).freeze
        @view = view
        @receipt = normalize_hash(receipt).freeze
        @errors = Array(errors).map { |error| normalize_hash(error).freeze }.freeze
        @warnings = Array(warnings).map { |warning| normalize_hash(warning).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @generated_at = generated_at
        @execution_boundary = token(execution_boundary)
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def pinned? = status == :pinned

      def blocked? = status == :blocked

      def reproducible? = meaning_status == :reproducible

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          meaning_status: meaning_status,
          name: name,
          owner: owner,
          action: action,
          actor: actor,
          capabilities: capabilities,
          missing_capabilities: missing_capabilities,
          horizon: horizon,
          view: serialize(view),
          receipt: receipt,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
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
