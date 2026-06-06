# frozen_string_literal: true

module Igniter
  module DurableModel
    # Read-only result of verifying an evidence export or archived export.
    class CommandFlowEvidenceExportVerification
      attr_reader :schema_version, :kind, :status, :export_id,
                  :expected_hash, :actual_hash, :privacy, :diagnostics,
                  :metadata, :generated_at

      def initialize(status:, export_id:, expected_hash:, actual_hash:,
                     privacy:, diagnostics: [], metadata: {},
                     generated_at: Time.now.utc, schema_version: 1,
                     kind: :command_flow_evidence_export_verification)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @export_id = export_id
        @expected_hash = expected_hash
        @actual_hash = actual_hash
        @privacy = token(privacy)
        @diagnostics = Array(diagnostics).map { |entry| normalize_hash(entry).freeze }.freeze
        @metadata = normalize_hash(metadata).freeze
        @generated_at = generated_at
        freeze
      end

      def valid? = status == :valid

      def invalid? = status == :invalid

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          export_id: export_id,
          expected_hash: expected_hash,
          actual_hash: actual_hash,
          privacy: privacy,
          diagnostics: diagnostics,
          metadata: metadata,
          generated_at: generated_at
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
