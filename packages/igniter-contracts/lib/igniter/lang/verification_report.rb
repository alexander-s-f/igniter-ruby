# frozen_string_literal: true

module Igniter
  module Lang
    class VerificationReport
      METADATA_CARRIER_SECTIONS = %i[
        diagnostics
        receipts
        model_validity_reports
        scenario_comparison_reports
        review_receipts
      ].freeze
      CUSTOM_METADATA_CARRIER_SECTIONS_KEY = :custom_sections

      METADATA_CARRIER_SEMANTICS = {
        report_only: true,
        runtime_enforced: false,
        execution_authorized: false,
        provider_call_authorized: false,
        real_data_export_authorized: false,
        readiness_enforced: false,
        ledger_core: false
      }.freeze

      DEFAULT_METADATA_REDACTION_POLICY = {
        raw_ref_export: false,
        hash_source_refs: true,
        redacted_ref_kinds: []
      }.freeze

      RAW_REF_KEYS = %i[raw_ref raw_refs raw_source_ref raw_source_refs].freeze
      RAW_REF_PREFIX = "raw:"

      attr_reader :profile_fingerprint,
                  :operations,
                  :findings,
                  :descriptors,
                  :metadata,
                  :metadata_manifest,
                  :carrier_manifest,
                  :diagnostic_payloads,
                  :receipt_payloads,
                  :schema_compatibility_diagnostics

      def self.from_compilation_report(report)
        new(
          profile_fingerprint: report.profile_fingerprint,
          operations: report.operations,
          findings: report.findings.map(&:to_h),
          metadata: { source: :compilation_report }
        )
      end

      def self.from_artifact(artifact, profile_fingerprint:)
        operations = artifact ? artifact.operations : []
        new(
          profile_fingerprint: profile_fingerprint,
          operations: operations,
          findings: [],
          metadata: { source: :compiled_artifact }
        )
      end

      def initialize(
        profile_fingerprint:,
        operations:,
        findings: [],
        metadata: {},
        diagnostic_payloads: [],
        receipt_payloads: [],
        schema_compatibility_diagnostics: []
      )
        @profile_fingerprint = profile_fingerprint
        @operations = operations.freeze
        @findings = findings.freeze
        @metadata = normalize_metadata(metadata)
        @metadata_manifest = MetadataManifest.from_operations(operations)
        @carrier_manifest = MetadataCarrierManifest.from_metadata(@metadata)
        @descriptors = metadata_manifest.descriptors
        @diagnostic_payloads = normalize_diagnostic_payloads(diagnostic_payloads)
        @receipt_payloads = normalize_receipt_payloads(receipt_payloads)
        @schema_compatibility_diagnostics = normalize_schema_compatibility_diagnostics(
          schema_compatibility_diagnostics
        )
        freeze
      end

      def ok?
        findings.empty?
      end

      def invalid?
        !ok?
      end

      def to_h
        {
          ok: ok?,
          profile_fingerprint: profile_fingerprint,
          descriptors: descriptors,
          metadata_manifest: metadata_manifest.to_h,
          carrier_manifest: carrier_manifest.to_h,
          diagnostic_payloads: diagnostic_payloads.map(&:to_h),
          receipt_payloads: receipt_payloads.map(&:to_h),
          schema_compatibility_diagnostics: schema_compatibility_diagnostics.map(&:to_h),
          findings: findings,
          metadata: metadata
        }
      end

      private

      def normalize_metadata(value)
        metadata_hash = normalize_hash(value, :metadata)
        return deep_freeze(metadata_hash) unless metadata_carrier?(metadata_hash)

        raise ArgumentError, "metadata.redaction_policy is required for carrier sections" unless metadata_hash.key?(:redaction_policy)

        metadata_hash[:redaction_policy] = normalize_metadata_redaction_policy(metadata_hash[:redaction_policy])
        metadata_hash[:semantics] = normalize_metadata_semantics(metadata_hash[:semantics] || {})
        reject_metadata_raw_refs!(metadata_hash)
        deep_freeze(metadata_hash)
      end

      def metadata_carrier?(metadata_hash)
        METADATA_CARRIER_SECTIONS.any? { |section| metadata_hash.key?(section) } ||
          metadata_hash.key?(CUSTOM_METADATA_CARRIER_SECTIONS_KEY)
      end

      def normalize_metadata_redaction_policy(value)
        policy = DEFAULT_METADATA_REDACTION_POLICY.merge(normalize_hash(value, :redaction_policy))
        raise ArgumentError, "metadata.redaction_policy.raw_ref_export must be true or false" unless [true, false].include?(policy[:raw_ref_export])
        raise ArgumentError, "metadata.redaction_policy.raw_ref_export true is not supported in v0" if policy[:raw_ref_export]

        policy[:redacted_ref_kinds] = Array(policy[:redacted_ref_kinds]).map(&:to_s)
        policy
      end

      def normalize_metadata_semantics(value)
        normalize_hash(value, :semantics).merge(METADATA_CARRIER_SEMANTICS)
      end

      def reject_metadata_raw_refs!(metadata_hash)
        raw_path = find_raw_ref(metadata_hash)
        raise ArgumentError, "raw refs are not allowed in verification metadata at metadata.#{raw_path}" if raw_path
      end

      def normalize_diagnostic_payloads(entries)
        entries.map do |entry|
          next entry if entry.is_a?(DiagnosticPayload)

          DiagnosticPayload.new(**entry.to_h.transform_keys(&:to_sym))
        end.freeze
      end

      def normalize_receipt_payloads(entries)
        entries.map do |entry|
          next entry if entry.is_a?(ReceiptPayload)

          ReceiptPayload.new(**entry.to_h.transform_keys(&:to_sym))
        end.freeze
      end

      def normalize_schema_compatibility_diagnostics(entries)
        entries.map do |entry|
          next entry if entry.is_a?(SchemaCompatibilityDiagnostic)

          SchemaCompatibilityDiagnostic.new(**entry.to_h.transform_keys(&:to_sym))
        end.freeze
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
