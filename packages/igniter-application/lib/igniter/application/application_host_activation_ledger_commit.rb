# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationHostActivationLedgerCommit
      SCHEMA_VERSION = "activation-ledger-v1"
      REQUIRED_PACKET_FIELDS = %i[
        packet_id
        schema_version
        transfer_receipt_id
        activation_readiness_id
        activation_plan_id
        activation_plan_verification_id
        activation_dry_run_id
        commit_readiness_id
        operation_digest
        commit_decision
        idempotency_key
        caller_metadata
        receipt_sink
        application_host_adapter
        dry_run
        commit_readiness
      ].freeze

      attr_reader :packet, :adapter, :metadata

      def self.commit(evidence_packet, adapter:, metadata: {})
        new(evidence_packet: evidence_packet, adapter: adapter, metadata: metadata)
      end

      def initialize(evidence_packet:, adapter:, metadata: {})
        @packet = normalize_hash(evidence_packet).freeze
        @adapter = adapter
        @metadata = metadata.dup.freeze
        @validation_refusals = (packet_refusals + evidence_refusals + adapter_refusals).freeze
        @acknowledgements = acknowledge_operations.freeze
        @refusals = (@validation_refusals + acknowledgement_refusals).freeze
        freeze
      end

      def committed?
        refusals.empty?
      end

      def to_h
        {
          result_id: result_id,
          packet_id: value(packet, :packet_id),
          operation_digest: operation_digest,
          committed: committed?,
          dry_run: false,
          applied_operations: applied_operations,
          skipped_operations: skipped_operations,
          refusals: refusals,
          warnings: [],
          adapter_receipts: adapter_receipts,
          metadata: metadata.dup
        }
      end

      private

      attr_reader :acknowledgements, :refusals, :validation_refusals

      def result_id
        "activation-ledger-result:#{value(packet, :packet_id)}"
      end

      def applied_operations
        return [] unless committed?

        acknowledgements.map do |entry|
          record = entry.fetch(:record)
          {
            type: operation_type(value(record, :operation)),
            status: :acknowledged,
            receipt_id: value(record, :receipt_id),
            adapter: adapter.to_h
          }
        end
      end

      def skipped_operations
        dry_run_skipped.map(&:dup)
      end

      def adapter_receipts
        return [] unless committed?

        acknowledgements.map { |entry| entry.fetch(:record) }
      end

      def acknowledge_operations
        return [] unless validation_refusals.empty?

        dry_run_would_apply.map do |operation|
          adapter.acknowledge(
            packet_id: value(packet, :packet_id),
            operation: operation,
            operation_digest: operation_digest,
            idempotency_key: value(packet, :idempotency_key),
            caller_metadata: value(packet, :caller_metadata)
          )
        end
      end

      def acknowledgement_refusals
        acknowledgements.filter_map do |entry|
          entry.fetch(:refusal) if entry.fetch(:status) == :refused
        end
      end

      def packet_refusals
        [].tap do |items|
          missing_packet_fields.each do |field|
            items << refusal(:missing_evidence_field, "Activation evidence packet is missing a required field.", field)
          end
          items << refusal(:unsupported_schema_version, "Activation evidence packet schema version is not supported.", value(packet, :schema_version)) unless
            value(packet, :schema_version) == SCHEMA_VERSION
          items << refusal(:commit_not_explicit, "Activation ledger commit requires explicit commit_decision: true.", value(packet, :commit_decision)) unless
            value(packet, :commit_decision) == true
          items << refusal(:receipt_sink_missing, "Activation ledger commit requires an explicit receipt sink.", value(packet, :receipt_sink)) if
            value(packet, :receipt_sink).to_s.empty?
          identity_refusals.each do |entry|
            items << entry
          end
          forbidden_fields.each do |field|
            items << refusal(:forbidden_evidence_field, "Activation evidence packet contains a forbidden live/runtime field.", field)
          end
        end
      end

      def evidence_refusals
        [].tap do |items|
          items << refusal(:operation_digest_mismatch, "Activation evidence operation digest does not match dry-run evidence.", operation_digest) unless
            operation_digest == computed_operation_digest
          items << refusal(:dry_run_missing, "Activation ledger commit requires dry-run evidence.", dry_run_payload) unless
            value(dry_run_payload, :dry_run) == true
          items << refusal(:dry_run_committed, "Activation ledger commit cannot consume committed dry-run evidence.", dry_run_payload) if
            value(dry_run_payload, :committed) == true
          items << refusal(:dry_run_not_executable, "Activation dry-run evidence is not executable.", dry_run_payload) unless
            value(dry_run_payload, :executable) == true
          dry_run_refusals.each do |entry|
            items << refusal(:dry_run_refusal, "Activation dry-run has unresolved refusals.", entry)
          end
          readiness_blockers.each do |entry|
            items << refusal(:commit_readiness_blocker, "Activation commit readiness has unresolved blockers.", entry)
          end
        end
      end

      def adapter_refusals
        [].tap do |items|
          missing_adapter_methods.each do |method_name|
            items << refusal(:missing_adapter_capability, "Activation ledger adapter is missing a required capability.", method_name)
          end
          next unless missing_adapter_methods.empty?

          dry_run_would_apply.each do |operation|
            type = operation_type(operation)
            items << refusal(:unsupported_operation_type, "Activation ledger adapter does not support operation type.", operation) unless
              adapter.supports?(type)
          end
        end
      end

      def missing_adapter_methods
        %i[supports? acknowledge readback to_h].reject { |method_name| adapter.respond_to?(method_name) }
      end

      def identity_refusals
        {
          activation_dry_run_id: dry_run_payload,
          commit_readiness_id: commit_readiness_payload
        }.filter_map do |field, payload|
          evidence_id = evidence_identity(payload, field)
          next if evidence_id.nil? || evidence_id == value(packet, field)

          refusal(:stale_evidence_identity, "Activation evidence identity does not match packet identity.", {
                    field: field,
                    packet_value: value(packet, field),
                    evidence_value: evidence_id
                  })
        end
      end

      def missing_packet_fields
        REQUIRED_PACKET_FIELDS.select { |field| missing?(value(packet, field)) }
      end

      def forbidden_fields
        %i[
          live_host
          constants
          loaded_classes
          rack_app
          route_table
          rendered_output
          contract_results
          cluster_placement
          discovery_results
          discovery
          discover
          adapter_registry
          lookup
          destination
          destination_root
          host_target
          target
        ].reject { |field| missing?(value(packet, field)) }
      end

      def missing?(item)
        item.nil? || (item.respond_to?(:empty?) && item.empty?)
      end

      def dry_run_payload
        normalize_hash(value(packet, :dry_run))
      end

      def commit_readiness_payload
        normalize_hash(value(packet, :commit_readiness))
      end

      def dry_run_would_apply
        Array(value(dry_run_payload, :would_apply)).map { |entry| normalize_hash(entry) }
      end

      def dry_run_skipped
        Array(value(dry_run_payload, :skipped)).map { |entry| normalize_hash(entry) }
      end

      def dry_run_refusals
        Array(value(dry_run_payload, :refusals)).map { |entry| normalize_hash(entry) }
      end

      def readiness_blockers
        Array(value(commit_readiness_payload, :blockers)).map { |entry| normalize_hash(entry) }
      end

      def operation_digest
        value(packet, :operation_digest)
      end

      def computed_operation_digest
        ApplicationHostActivationOperationDigest.compute(dry_run_payload)
      end

      def evidence_identity(payload, field)
        candidates = [field, :id, :result_id, :evidence_id]
        candidates.each do |candidate|
          candidate_value = value(payload, candidate)
          return candidate_value unless missing?(candidate_value)
        end
        nil
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

      def refusal(code, message, entry)
        {
          code: code,
          message: message,
          entry: entry
        }
      end
    end
  end
end
