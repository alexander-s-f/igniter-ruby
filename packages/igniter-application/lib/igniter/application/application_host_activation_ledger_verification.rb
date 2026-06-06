# frozen_string_literal: true

require "time"

module Igniter
  module Application
    class ApplicationHostActivationLedgerVerification
      attr_reader :packet, :commit_result, :adapter, :metadata

      def self.verify(evidence_packet, commit_result:, adapter:, metadata: {})
        new(
          evidence_packet: evidence_packet,
          commit_result: commit_result,
          adapter: adapter,
          metadata: metadata
        )
      end

      def initialize(evidence_packet:, commit_result:, adapter:, metadata: {})
        @packet = normalize_hash(evidence_packet).freeze
        @commit_result = normalize_hash(commit_result.respond_to?(:to_h) ? commit_result.to_h : commit_result).freeze
        @adapter = adapter
        @metadata = metadata.dup.freeze
        @readbacks = readback_records.freeze
        @findings = build_findings.freeze
        freeze
      end

      def valid?
        findings.empty?
      end

      def complete?
        valid? && committed? && verified_operations.length == expected_operations.length
      end

      def to_h
        {
          verification_id: verification_id,
          packet_id: packet_id,
          result_id: result_id,
          operation_digest: operation_digest,
          idempotency_key: idempotency_key,
          valid: valid?,
          complete: complete?,
          committed: committed?,
          findings: findings,
          verified_operations: verified_operations,
          unexpected_operations: unexpected_operations,
          adapter_readbacks: readbacks,
          counts: counts,
          skipped_operations: skipped_operations,
          verified_at: Time.now.utc.iso8601,
          metadata: metadata.dup
        }
      end

      private

      attr_reader :readbacks, :findings

      def verification_id
        "activation-ledger-verification:#{packet_id}:#{operation_digest}"
      end

      def packet_id
        value(packet, :packet_id)
      end

      def result_id
        value(commit_result, :result_id)
      end

      def operation_digest
        value(packet, :operation_digest)
      end

      def idempotency_key
        value(packet, :idempotency_key)
      end

      def committed?
        value(commit_result, :committed) == true
      end

      def build_findings
        [].tap do |items|
          items << finding(:commit_not_committed, "Activation commit result is not committed.", commit_result) unless
            committed?
          items.concat(result_identity_findings)
          items.concat(applied_operation_findings)
          items.concat(identity_findings)
          items.concat(missing_findings)
          items.concat(unexpected_findings)
          items.concat(duplicate_findings)
          items.concat(commit_receipt_findings)
        end
      end

      def result_identity_findings
        [
          [:result_packet_id_mismatch, :packet_id, packet_id],
          [:result_operation_digest_mismatch, :operation_digest, operation_digest]
        ].filter_map do |code, field, expected|
          actual = value(commit_result, field)
          next if actual == expected

          finding(code, "Activation commit result identity does not match evidence packet.", {
                    field: field,
                    expected: expected,
                    actual: actual
                  })
        end
      end

      def applied_operation_findings
        return [] if applied_operation_types.sort == expected_operation_types.sort

        [
          finding(:applied_operation_mismatch, "Activation commit result applied operations do not match packet.", {
                    expected_types: expected_operation_types,
                    actual_types: applied_operation_types
                  })
        ]
      end

      def identity_findings
        [
          [:packet_id_mismatch, :packet_id, packet_id],
          [:operation_digest_mismatch, :operation_digest, operation_digest],
          [:idempotency_key_mismatch, :idempotency_key, idempotency_key]
        ].flat_map do |code, field, expected|
          readbacks.filter_map do |record|
            actual = value(record, field)
            next if actual == expected

            finding(code, "Activation ledger readback identity does not match evidence packet.", {
                      field: field,
                      expected: expected,
                      actual: actual,
                      receipt_id: value(record, :receipt_id)
                    })
          end
        end
      end

      def missing_findings
        expected_operation_keys.filter_map do |operation_key|
          next if readback_by_operation.key?(operation_key)

          finding(:missing_ledger_record, "Activation ledger readback is missing an expected operation.", {
                    operation_key: operation_key
                  })
        end
      end

      def unexpected_findings
        unexpected_operations.map do |record|
          finding(:unexpected_ledger_record, "Activation ledger readback contains an unplanned operation.", record)
        end
      end

      def duplicate_findings
        readback_by_operation.filter_map do |operation_key, records|
          next unless records.length > 1

          finding(:duplicate_ledger_record, "Activation ledger readback contains duplicate operation records.", {
                    operation_key: operation_key,
                    receipt_ids: records.map { |record| value(record, :receipt_id) }
                  })
        end
      end

      def commit_receipt_findings
        commit_receipts.filter_map do |record|
          receipt_id = value(record, :receipt_id)
          next if readbacks.any? { |readback| value(readback, :receipt_id) == receipt_id }

          finding(:commit_receipt_missing_from_readback, "Commit receipt was not returned by adapter readback.", record)
        end
      end

      def verified_operations
        expected_operations.filter_map do |operation|
          records = readback_by_operation.fetch(operation_key(operation), [])
          next unless records.length == 1 && record_matches_expected?(records.first)

          {
            type: operation_type(operation),
            operation_key: operation_key(operation),
            receipt_id: value(records.first, :receipt_id),
            status: :verified
          }
        end
      end

      def unexpected_operations
        readbacks.reject { |record| expected_operation_keys.include?(record_operation_key(record)) }
      end

      def readback_by_operation
        @readback_by_operation ||= readbacks.group_by { |record| record_operation_key(record) }
      end

      def readback_records
        return [] unless adapter.respond_to?(:readback)

        adapter.readback(idempotency_key: idempotency_key, operation_digest: operation_digest).map do |record|
          normalize_hash(record)
        end
      end

      def record_matches_expected?(record)
        value(record, :packet_id) == packet_id &&
          value(record, :operation_digest) == operation_digest &&
          value(record, :idempotency_key) == idempotency_key
      end

      def expected_operations
        Array(value(dry_run_payload, :would_apply)).map { |entry| normalize_hash(entry) }
      end

      def expected_operation_keys
        @expected_operation_keys ||= expected_operations.map { |operation| operation_key(operation) }
      end

      def commit_receipts
        Array(value(commit_result, :adapter_receipts)).map { |entry| normalize_hash(entry) }
      end

      def applied_operations
        Array(value(commit_result, :applied_operations)).map { |entry| normalize_hash(entry) }
      end

      def applied_operation_types
        applied_operations.map { |entry| operation_type(entry) }
      end

      def expected_operation_types
        expected_operations.map { |entry| operation_type(entry) }
      end

      def skipped_operations
        Array(value(commit_result, :skipped_operations)).map { |entry| normalize_hash(entry) }
      end

      def counts
        {
          expected: expected_operations.length,
          readback: readbacks.length,
          verified: verified_operations.length,
          unexpected: unexpected_operations.length,
          findings: findings.length,
          skipped: skipped_operations.length
        }
      end

      def dry_run_payload
        normalize_hash(value(packet, :dry_run))
      end

      def record_operation_key(record)
        operation = normalize_hash(value(record, :operation))
        value(operation, :operation_key) || operation_key(operation)
      end

      def operation_key(operation)
        [
          value(operation, :type),
          value(operation, :destination),
          value(operation, :source)
        ].join(":")
      end

      def operation_type(operation)
        type = value(operation, :type)
        type.respond_to?(:to_sym) ? type.to_sym : type
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

      def finding(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
