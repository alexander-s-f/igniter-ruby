# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationPlan
      attr_reader :readiness_payload, :metadata, :operations, :decisions

      def self.build(readiness, metadata: {})
        new(readiness: readiness, metadata: metadata)
      end

      def initialize(readiness:, metadata: {})
        @readiness_payload = payload_from(readiness).freeze
        @metadata = metadata.dup.freeze
        @decisions = normalize_decisions(value(readiness_payload, :decisions)).freeze
        @operations = build_operations.freeze
        freeze
      end

      def executable?
        value(readiness_payload, :ready) == true && blockers.empty?
      end

      def to_h
        {
          executable: executable?,
          operations: operations,
          blockers: blockers,
          warnings: warnings,
          surface_count: surface_count,
          metadata: metadata.dup
        }
      end

      private

      def build_operations
        return [] unless executable?

        host_export_operations +
          host_capability_operations +
          load_path_operations +
          provider_operations +
          contract_operations +
          lifecycle_operations +
          manual_action_operations +
          mount_intent_operations
      end

      def host_export_operations
        decisions.fetch(:host_exports, []).map do |entry|
          operation(
            type: :confirm_host_export,
            source: :activation_readiness_host_export,
            destination: value(entry, :name),
            metadata: { entry: entry.dup }
          )
        end
      end

      def host_capability_operations
        decisions.fetch(:host_capabilities, []).map do |capability|
          operation(
            type: :confirm_host_capability,
            source: :activation_readiness_host_capability,
            destination: capability,
            metadata: { capability: capability }
          )
        end
      end

      def load_path_operations
        decisions.fetch(:load_paths, []).map do |path|
          operation(
            type: :confirm_load_path,
            source: :activation_readiness_load_path,
            destination: path,
            metadata: { path: path }
          )
        end
      end

      def provider_operations
        decisions.fetch(:providers, []).map do |provider|
          operation(
            type: :confirm_provider,
            source: :activation_readiness_provider,
            destination: provider,
            metadata: { provider: provider }
          )
        end
      end

      def contract_operations
        decisions.fetch(:contracts, []).map do |contract|
          operation(
            type: :confirm_contract,
            source: :activation_readiness_contract,
            destination: contract,
            metadata: { contract: contract }
          )
        end
      end

      def lifecycle_operations
        decisions.fetch(:lifecycle, {}).keys.sort_by(&:to_s).map do |key|
          operation(
            type: :confirm_lifecycle,
            source: :activation_readiness_lifecycle,
            destination: key,
            metadata: { key: key, value: decisions.fetch(:lifecycle).fetch(key) }
          )
        end
      end

      def manual_action_operations
        return [] if manual_actions.empty?

        [
          operation(
            type: :acknowledge_manual_actions,
            source: :activation_readiness_manual_actions,
            destination: :host,
            metadata: { count: manual_actions.length, actions: manual_actions.map(&:dup) }
          )
        ]
      end

      def mount_intent_operations
        mount_intents.map do |entry|
          operation(
            type: :review_mount_intent,
            source: :activation_readiness_mount_intent,
            destination: value(entry, :at),
            metadata: { intent: entry.dup }
          )
        end
      end

      def operation(type:, source:, destination:, metadata:)
        {
          type: type,
          status: :review_required,
          source: source,
          destination: destination,
          metadata: metadata
        }
      end

      def normalize_decisions(raw_decisions)
        source = normalize_hash(raw_decisions)
        source.merge(
          host_exports: Array(value(source, :host_exports)).map { |entry| normalize_hash(entry) },
          host_capabilities: Array(value(source, :host_capabilities)),
          load_paths: Array(value(source, :load_paths)),
          providers: Array(value(source, :providers)),
          contracts: Array(value(source, :contracts)),
          lifecycle: normalize_hash(value(source, :lifecycle))
        )
      end

      def manual_actions
        Array(value(readiness_payload, :manual_actions)).map { |entry| normalize_hash(entry) }
      end

      def mount_intents
        Array(value(readiness_payload, :mount_intents)).map { |entry| normalize_hash(entry) }
      end

      def blockers
        Array(value(readiness_payload, :blockers)).map { |entry| normalize_hash(entry) }
      end

      def warnings
        Array(value(readiness_payload, :warnings)).map { |entry| normalize_hash(entry) }
      end

      def surface_count
        value(readiness_payload, :surface_count) || 0
      end

      def payload_from(source)
        payload = source.respond_to?(:to_h) ? source.to_h : source
        normalize_hash(payload)
      end

      def normalize_hash(value)
        source = value.respond_to?(:to_h) ? value.to_h : {}
        source.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:key?)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
