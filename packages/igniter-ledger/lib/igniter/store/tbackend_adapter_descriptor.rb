# frozen_string_literal: true

require "digest"
require "json"

module Igniter
  module Store
    class TBackendAdapterDescriptor
      KIND = "ledger_tbackend_adapter_descriptor"
      DIAGNOSTICS_KIND = "ledger_tbackend_adapter_descriptor_diagnostics"
      ADAPTER_KIND = "ledger_open_protocol"
      ADAPTER_VERSION = "0.1.0"
      CONTRACT_VERSION = "tbackend.v0"
      PROTOCOL = "igniter_store"
      EVIDENCE_MODE = "receipt_required"
      DEFAULT_ADAPTER_REF = "adapter:ledger-open-protocol/package-descriptor-v0"

      READ_OPS = %w[read query fact_ref].freeze
      APPEND_OPS = %w[write write_fact append].freeze
      REPLAY_OPS = %w[replay sync_hub_profile].freeze
      SNAPSHOT_OPS = %w[metadata_snapshot descriptor_snapshot sync_hub_profile].freeze
      TBACKEND_OPS = {
        "read" => READ_OPS,
        "append" => APPEND_OPS,
        "replay" => REPLAY_OPS,
        "snapshot" => SNAPSHOT_OPS,
        "compact" => %w[compact],
        "subscribe" => %w[subscribe]
      }.freeze

      CURSOR_POLICY = {
        ordered: "forward",
        cursor_kinds: ["timestamp"],
        truncation_reported: true,
        tie_breaker: "timestamp_then_fact_id_required"
      }.freeze

      NON_AUTHORIZATION = {
        runtime_binding: false,
        ledger_reads: false,
        ledger_writes: false,
        ledger_append: false,
        ledger_replay: false,
        ledger_compact: false,
        ledger_subscribe: false,
        migration_execution: false
      }.freeze

      attr_reader :metadata_snapshot,
                  :descriptor_snapshot,
                  :payload

      def self.build(metadata_snapshot:, descriptor_snapshot:, schema_fingerprint:, adapter_ref: nil,
                     ledger_protocol_ops: nil)
        new(
          metadata_snapshot: metadata_snapshot,
          descriptor_snapshot: descriptor_snapshot,
          schema_fingerprint: schema_fingerprint,
          adapter_ref: adapter_ref,
          ledger_protocol_ops: ledger_protocol_ops
        )
      end

      def initialize(metadata_snapshot:, descriptor_snapshot:, schema_fingerprint:, adapter_ref: nil,
                     ledger_protocol_ops: nil)
        @metadata_snapshot = normalize_hash(metadata_snapshot, :metadata_snapshot)
        @descriptor_snapshot = normalize_hash(descriptor_snapshot, :descriptor_snapshot)
        @payload = build_payload(
          schema_fingerprint: require_value(:schema_fingerprint, schema_fingerprint),
          adapter_ref: adapter_ref || DEFAULT_ADAPTER_REF,
          ledger_protocol_ops: normalize_ops(
            ledger_protocol_ops || metadata_snapshot_value(:ledger_protocol_ops) || metadata_snapshot_value(:protocol_ops)
          )
        )
        freeze
      end

      def descriptor_hash
        payload.fetch(:descriptor_hash)
      end

      def descriptor_registry_hash
        payload.fetch(:descriptor_registry_hash)
      end

      def ledger_protocol_ops
        payload.fetch(:ledger_protocol_ops)
      end

      def supported_tbackend_ops
        payload.fetch(:supported_tbackend_ops)
      end

      def hook_methods
        payload.fetch(:hook_methods)
      end

      def capabilities
        payload.fetch(:capabilities)
      end

      def history_axes
        payload.fetch(:history_axes)
      end

      def cursor_policy
        payload.fetch(:cursor_policy)
      end

      def diagnostics(requirement = {})
        requirement = normalize_hash(requirement, :requirement)
        missing_ops = missing(:required_ops, :supported_tbackend_ops, requirement)
        missing_hook_methods = missing(:required_hook_methods, :hook_methods, requirement)
        missing_capabilities = missing(:required_capabilities, :capabilities, requirement)
        missing_axes = missing(:history_axes, :history_axes, requirement)
        schema_fingerprint_match = schema_fingerprint_match?(requirement)
        blocked = missing_ops.any? ||
                  missing_hook_methods.any? ||
                  missing_capabilities.any? ||
                  missing_axes.any? ||
                  !schema_fingerprint_match

        deep_freeze(
          kind: DIAGNOSTICS_KIND,
          status: blocked ? "blocked" : "ok",
          missing_ops: missing_ops,
          missing_hook_methods: missing_hook_methods,
          missing_capabilities: missing_capabilities,
          missing_axes: missing_axes,
          schema_fingerprint_match: schema_fingerprint_match,
          descriptor_hash: descriptor_hash,
          descriptor_registry_hash: descriptor_registry_hash
        )
      end

      def to_h
        payload
      end

      private

      def build_payload(schema_fingerprint:, adapter_ref:, ledger_protocol_ops:)
        supported_tbackend_ops = derive_supported_tbackend_ops(ledger_protocol_ops)
        hook_methods = []
        capabilities = []
        history_axes = []

        if history_read_supported?(supported_tbackend_ops)
          hook_methods << "read_as_of"
          capabilities << "history_read"
          history_axes << "valid_time"
        end

        if bihistory_supported?
          hook_methods << "bihistory_at"
          capabilities << "bihistory_read"
          history_axes << "transaction_time"
        end

        descriptor_registry_hash = self.class.canonical_hash(
          metadata_snapshot: metadata_snapshot,
          descriptor_snapshot: descriptor_snapshot
        )

        payload_without_hash = {
          kind: KIND,
          adapter_kind: ADAPTER_KIND,
          adapter_ref: adapter_ref,
          adapter_version: ADAPTER_VERSION,
          contract_version: CONTRACT_VERSION,
          protocol: PROTOCOL,
          protocol_schema_version: protocol_schema_version,
          ledger_protocol_ops: ledger_protocol_ops,
          supported_tbackend_ops: supported_tbackend_ops,
          hook_methods: hook_methods,
          capabilities: capabilities,
          history_axes: history_axes,
          cursor_policy: CURSOR_POLICY,
          schema_fingerprint: schema_fingerprint,
          descriptor_registry_hash: descriptor_registry_hash,
          evidence_mode: EVIDENCE_MODE,
          source_snapshots: {
            metadata_snapshot_present: true,
            descriptor_snapshot_present: true
          },
          non_authorization: NON_AUTHORIZATION
        }

        deep_freeze(payload_without_hash.merge(
                      descriptor_hash: self.class.canonical_hash(payload_without_hash)
                    ))
      end

      def protocol_schema_version
        metadata_snapshot[:schema_version] || descriptor_snapshot[:schema_version]
      end

      def derive_supported_tbackend_ops(ledger_protocol_ops)
        TBACKEND_OPS.filter_map do |tbackend_op, ledger_ops|
          tbackend_op if (ledger_protocol_ops & ledger_ops).any?
        end
      end

      def history_read_supported?(supported_tbackend_ops)
        supported_tbackend_ops.include?("read") && store_descriptors.any? do |descriptor|
          descriptor_capabilities(descriptor).include?("as_of_read")
        end
      end

      def bihistory_supported?
        history_descriptors.any?
      end

      def store_descriptors
        Array(metadata_snapshot[:stores]) + Array(descriptor_snapshot[:stores])
      end

      def history_descriptors
        Array(metadata_snapshot[:histories]) + Array(descriptor_snapshot[:histories])
      end

      def descriptor_capabilities(descriptor)
        Array(descriptor[:capabilities]).map(&:to_s)
      end

      def missing(requirement_key, descriptor_key, requirement)
        required = Array(requirement[requirement_key]).map(&:to_s)
        actual = Array(payload.fetch(descriptor_key)).map(&:to_s)
        required - actual
      end

      def schema_fingerprint_match?(requirement)
        required = requirement[:schema_fingerprint]
        required.nil? || required == payload.fetch(:schema_fingerprint)
      end

      def metadata_snapshot_value(key)
        metadata_snapshot[key]
      end

      def normalize_ops(value)
        Array(value).map(&:to_s).uniq.freeze
      end

      def require_value(name, value)
        raise ArgumentError, "#{name} is required" if value.nil?

        value
      end

      def normalize_hash(value, name)
        raise ArgumentError, "#{name} must be a hash" unless value.respond_to?(:to_h)

        value.to_h.each_with_object({}) do |(key, entry), hash|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          hash[normalized_key] = normalize_value(entry)
        end
      end

      def normalize_value(value)
        case value
        when Hash
          normalize_hash(value, :value)
        when Array
          value.map { |entry| normalize_value(entry) }
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        when Hash
          value.transform_values { |entry| deep_freeze(entry) }.freeze
        else
          value.freeze
        end
      end

      class << self
        def canonical_hash(value)
          "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical_value(value)))}"
        end

        private

        def canonical_value(value)
          case value
          when Hash
            value.keys.map(&:to_s).sort.each_with_object({}) do |key, hash|
              original_key = value.key?(key.to_sym) ? key.to_sym : key
              hash[key] = canonical_value(value.fetch(original_key))
            end
          when Array
            value.map { |entry| canonical_value(entry) }
          when Symbol
            value.to_s
          else
            value
          end
        end
      end
    end
  end
end
