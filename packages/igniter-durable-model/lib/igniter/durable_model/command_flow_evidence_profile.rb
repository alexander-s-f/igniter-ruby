# frozen_string_literal: true

module Igniter
  module DurableModel
    # Portable app-safe evidence bundle over command-flow operational state.
    class CommandFlowEvidenceProfile
      attr_reader :schema_version, :kind, :owner, :view_name, :action, :actor,
                  :status, :meaning_status, :generated_at, :horizon, :view,
                  :pin, :review, :decisions, :packets, :links, :metadata,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(owner:, view_name:, status:, meaning_status:, horizon:,
                     view:, review:, decisions:, action: nil, actor: nil,
                     pin: nil, packets: [], links: [], metadata: {},
                     generated_at: Time.now.utc, schema_version: 1,
                     kind: :command_flow_evidence_profile,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @owner = token(owner)
        @view_name = token(view_name)
        @action = token(action)
        @actor = actor
        @status = token(status)
        @meaning_status = token(meaning_status)
        @generated_at = generated_at
        @horizon = normalize_hash(horizon).freeze
        @view = normalize_artifact(view).freeze
        @pin = pin.nil? ? nil : normalize_artifact(pin).freeze
        @review = normalize_artifact(review).freeze
        @decisions = Array(decisions).map { |decision| normalize_artifact(decision).freeze }.freeze
        @packets = Array(packets).map { |packet| normalize_hash(packet).freeze }.freeze
        @links = Array(links).map { |link| normalize_hash(link).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def ok? = status == :ok

      def warning? = status == :warning

      def critical? = status == :critical

      def blocked? = status == :blocked

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          owner: owner,
          view_name: view_name,
          action: action,
          actor: actor,
          status: status,
          meaning_status: meaning_status,
          generated_at: generated_at,
          horizon: horizon,
          view: view,
          pin: pin,
          review: review,
          decisions: decisions,
          packets: packets,
          links: links,
          metadata: metadata,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def normalize_artifact(value)
        data = value.respond_to?(:to_h) ? value.to_h : value
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
