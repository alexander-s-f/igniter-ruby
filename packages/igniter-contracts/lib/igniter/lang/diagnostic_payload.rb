# frozen_string_literal: true

module Igniter
  module Lang
    class DiagnosticPayload
      SEMANTICS = {
        report_only: true,
        runtime_enforced: false,
        package_adapter_authorized: false,
        real_data_export_authorized: false,
        readiness_enforced: false,
        ledger_core: false
      }.freeze

      DEFAULT_REDACTION_POLICY = {
        raw_ref_export: false,
        hash_source_refs: true,
        redacted_ref_kinds: []
      }.freeze

      STATUSES = %i[ok warning blocked unknown].freeze
      DECISIONS = %i[trusted provisional blocked unknown].freeze
      RAW_REF_KEYS = %i[raw_ref raw_refs raw_source_ref raw_source_refs].freeze
      RAW_REF_PREFIX = "raw:"

      attr_reader :diagnostic_id,
                  :profile,
                  :status,
                  :decision,
                  :payload,
                  :evidence_links,
                  :redaction_policy,
                  :metadata

      def initialize(
        diagnostic_id:,
        profile:,
        status:,
        decision:,
        payload: {},
        evidence_links: {},
        redaction_policy: {},
        metadata: {}
      )
        @diagnostic_id = require_value(:diagnostic_id, diagnostic_id)
        @profile = require_value(:profile, profile)
        @status = normalize_status(status)
        @decision = normalize_decision(decision)
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
          diagnostic_id: diagnostic_id,
          profile: profile,
          status: status,
          decision: decision,
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

      def normalize_status(value)
        status_value = require_value(:status, value).to_sym
        return status_value if STATUSES.include?(status_value)

        raise ArgumentError, "status must be one of #{STATUSES.join(", ")}"
      end

      def normalize_decision(value)
        decision_value = require_value(:decision, value).to_sym
        return decision_value if DECISIONS.include?(decision_value)

        raise ArgumentError, "decision must be one of #{DECISIONS.join(", ")}"
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
        raise ArgumentError, "raw refs are not allowed in diagnostic payloads at #{raw_path}" if raw_path
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
