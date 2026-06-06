# frozen_string_literal: true

module Igniter
  module Lang
    class ReceiptPayload
      SEMANTICS = {
        report_only: true,
        runtime_enforced: false,
        execution_authorized: false,
        operation_execution_authorized: false,
        external_bridge_authorized: false,
        provider_call_authorized: false,
        real_data_export_authorized: false,
        ledger_core: false
      }.freeze

      DEFAULT_REDACTION_POLICY = {
        raw_ref_export: false,
        hash_source_refs: true,
        redacted_ref_kinds: []
      }.freeze

      RAW_REF_KEYS = %i[raw_ref raw_refs raw_source_ref raw_source_refs].freeze
      RAW_REF_PREFIX = "raw:"

      attr_reader :receipt_id,
                  :profile,
                  :payload,
                  :evidence_links,
                  :redaction_policy,
                  :metadata

      def initialize(
        receipt_id:,
        profile:,
        payload: {},
        evidence_links: {},
        redaction_policy: {},
        metadata: {}
      )
        @receipt_id = require_value(:receipt_id, receipt_id)
        @profile = require_value(:profile, profile)
        @payload = deep_freeze(normalize_hash(payload, :payload))
        @evidence_links = deep_freeze(normalize_hash(evidence_links, :evidence_links))
        @redaction_policy = deep_freeze(normalize_redaction_policy(redaction_policy))
        @metadata = deep_freeze(normalize_hash(metadata, :metadata))
        reject_raw_refs!
        freeze
      end

      def report_only?
        true
      end

      def runtime_enforced?
        false
      end

      def to_h
        {
          receipt_id: receipt_id,
          profile: profile,
          payload: payload,
          evidence_links: evidence_links,
          redaction_policy: redaction_policy,
          semantics: SEMANTICS,
          metadata: metadata
        }
      end

      private

      def require_value(name, value)
        raise ArgumentError, "#{name} is required" if value.nil?

        value
      end

      def normalize_redaction_policy(value)
        policy = DEFAULT_REDACTION_POLICY.merge(normalize_hash(value, :redaction_policy))
        raise ArgumentError, "redaction_policy.raw_ref_export must be true or false" unless [true, false].include?(policy[:raw_ref_export])

        raise ArgumentError, "redaction_policy.raw_ref_export true is not supported in v0" if policy[:raw_ref_export]

        policy[:redacted_ref_kinds] = Array(policy[:redacted_ref_kinds]).map(&:to_s)
        policy
      end

      def reject_raw_refs!
        raw_path = find_raw_ref(
          payload: payload,
          evidence_links: evidence_links,
          metadata: metadata
        )
        raise ArgumentError, "raw refs are not allowed in receipt payloads at #{raw_path}" if raw_path
      end

      def find_raw_ref(value, path = [])
        case value
        when Hash
          value.each do |key, entry|
            normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
            return (path + [normalized_key]).join(".") if RAW_REF_KEYS.include?(normalized_key)

            nested = find_raw_ref(entry, path + [normalized_key])
            return nested if nested
          end
        when Array
          value.each_with_index do |entry, index|
            nested = find_raw_ref(entry, path + [index])
            return nested if nested
          end
        when String
          return path.join(".") if value.start_with?(RAW_REF_PREFIX)
        end

        nil
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
    end
  end
end
