# frozen_string_literal: true

require "time"

module Igniter
  module Application
    class ApplicationHostActivationReceipt
      SCHEMA_VERSION = "activation-receipt-v1"

      attr_reader :verification, :packet, :commit_result, :metadata

      def self.build(verification, evidence_packet:, commit_result:, metadata: {})
        new(
          verification: verification,
          evidence_packet: evidence_packet,
          commit_result: commit_result,
          metadata: metadata
        )
      end

      def initialize(verification:, evidence_packet:, commit_result:, metadata: {})
        @verification = normalize_hash(verification.respond_to?(:to_h) ? verification.to_h : verification).freeze
        @packet = normalize_hash(evidence_packet).freeze
        @commit_result = normalize_hash(commit_result.respond_to?(:to_h) ? commit_result.to_h : commit_result).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def valid?
        value(verification, :valid) == true
      end

      def complete?
        valid? && value(verification, :complete) == true && committed?
      end

      def committed?
        value(verification, :committed) == true && value(commit_result, :committed) == true
      end

      def to_h
        {
          activation_receipt_id: activation_receipt_id,
          schema_version: SCHEMA_VERSION,
          transfer_receipt_id: value(packet, :transfer_receipt_id),
          packet_id: value(packet, :packet_id),
          result_id: value(commit_result, :result_id),
          verification_id: value(verification, :verification_id),
          complete: complete?,
          valid: valid?,
          committed: committed?,
          operation_digest: value(packet, :operation_digest),
          counts: counts,
          manual_leftovers: manual_leftovers,
          host_leftovers: host_leftovers,
          web_leftovers: web_leftovers,
          adapter_receipt_refs: adapter_receipt_refs,
          audit_metadata: audit_metadata,
          issued_at: Time.now.utc.iso8601,
          metadata: metadata.dup
        }
      end

      private

      def activation_receipt_id
        "activation-receipt:#{value(packet, :transfer_receipt_id)}:#{value(packet, :packet_id)}"
      end

      def counts
        verification_counts.merge(
          applied: applied_operations.length,
          skipped: skipped_operations.length,
          adapter_receipts: adapter_receipt_refs.length,
          manual_leftovers: manual_leftovers.length,
          host_leftovers: host_leftovers.length,
          web_leftovers: web_leftovers.length
        )
      end

      def verification_counts
        counts = value(verification, :counts)
        counts.respond_to?(:to_h) ? normalize_hash(counts) : {}
      end

      def audit_metadata
        {
          receipt_kind: :activation_receipt,
          transfer_receipt_id: value(packet, :transfer_receipt_id),
          packet_id: value(packet, :packet_id),
          result_id: value(commit_result, :result_id),
          verification_id: value(verification, :verification_id),
          separate_from_transfer_receipt: true,
          metadata: metadata.dup
        }
      end

      def adapter_receipt_refs
        adapter_receipts.map do |record|
          {
            receipt_id: value(record, :receipt_id),
            packet_id: value(record, :packet_id),
            operation_digest: value(record, :operation_digest),
            idempotency_key: value(record, :idempotency_key),
            operation_key: value(normalize_hash(value(record, :operation)), :operation_key)
          }
        end
      end

      def manual_leftovers
        skipped_by_reason(:manual_host_action)
      end

      def host_leftovers
        skipped_by_reason(:host_owned_evidence)
      end

      def web_leftovers
        skipped_by_reason(:web_or_host_owned_mount)
      end

      def skipped_by_reason(reason)
        skipped_operations.select { |entry| value(entry, :reason).to_s == reason.to_s }
      end

      def applied_operations
        Array(value(commit_result, :applied_operations)).map { |entry| normalize_hash(entry) }
      end

      def skipped_operations
        Array(value(commit_result, :skipped_operations)).map { |entry| normalize_hash(entry) }
      end

      def adapter_receipts
        Array(value(commit_result, :adapter_receipts)).map { |entry| normalize_hash(entry) }
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
