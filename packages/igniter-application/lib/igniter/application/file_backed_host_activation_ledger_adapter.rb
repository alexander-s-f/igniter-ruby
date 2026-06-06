# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Igniter
  module Application
    class FileBackedHostActivationLedgerAdapter
      SUPPORTED_OPERATION_TYPES = %i[
        confirm_load_path
        confirm_provider
        confirm_contract
        confirm_lifecycle
      ].freeze

      attr_reader :root, :name, :kind

      def self.build(root:, name: :file_backed_host_activation_ledger)
        new(root: root, name: name)
      end

      def initialize(root:, name: :file_backed_host_activation_ledger)
        @root = File.expand_path(root.to_s)
        @name = name.to_sym
        @kind = :application_host_adapter
        freeze
      end

      def to_h
        {
          name: name,
          kind: kind,
          adapter_fingerprint: adapter_fingerprint,
          supported_operation_types: SUPPORTED_OPERATION_TYPES,
          dry_run_compatible: true,
          readback_supported: true,
          root: root
        }
      end

      def supports?(operation_type)
        SUPPORTED_OPERATION_TYPES.include?(operation_type.to_sym)
      end

      def acknowledge(packet_id:, operation:, operation_digest:, idempotency_key:, caller_metadata: {})
        conflict = readback(idempotency_key: idempotency_key).find do |record|
          value(record, :operation_digest) != operation_digest
        end
        return conflicting_idempotency_key(conflict) if conflict

        existing = readback(idempotency_key: idempotency_key, operation_digest: operation_digest).find do |record|
          value(value(record, :operation), :operation_key) == operation_key(operation)
        end
        return { status: :acknowledged, duplicate: true, record: existing } if existing

        FileUtils.mkdir_p(ledger_dir)
        record = {
          receipt_id: receipt_id(idempotency_key, operation_digest, operation),
          packet_id: packet_id,
          operation_digest: operation_digest,
          idempotency_key: idempotency_key,
          operation: normalize_hash(operation).merge(operation_key: operation_key(operation)),
          adapter: to_h,
          caller_metadata: normalize_hash(caller_metadata),
          acknowledged_at: Time.now.utc.iso8601
        }
        File.write(record_path(idempotency_key, operation), "#{JSON.pretty_generate(record)}\n")
        { status: :acknowledged, duplicate: false, record: record }
      end

      def readback(idempotency_key:, operation_digest: nil)
        pattern = File.join(ledger_dir, "#{safe_key(idempotency_key)}--*.json")
        Dir.glob(pattern).sort.filter_map do |path|
          record = normalize_hash(JSON.parse(File.read(path)))
          next if operation_digest && value(record, :operation_digest) != operation_digest

          record
        end
      end

      private

      def conflicting_idempotency_key(existing)
        {
          status: :refused,
          duplicate: true,
          refusal: {
            code: :idempotency_key_reused,
            message: "Idempotency key was already used with a different operation digest.",
            entry: existing
          }
        }
      end

      def ledger_dir
        File.join(root, "activation-ledger")
      end

      def record_path(idempotency_key, operation)
        File.join(ledger_dir, "#{safe_key(idempotency_key)}--#{safe_key(operation_key(operation))}.json")
      end

      def safe_key(value)
        value.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
      end

      def receipt_id(idempotency_key, operation_digest, operation)
        type = value(operation, :type) || "operation"
        "activation-ledger:#{safe_key(idempotency_key)}:#{safe_key(operation_digest)}:#{safe_key(type)}:#{safe_key(operation_key(operation))}"
      end

      def operation_key(operation)
        [
          value(operation, :type),
          value(operation, :destination),
          value(operation, :source)
        ].join(":")
      end

      def adapter_fingerprint
        "file-backed-host-activation-ledger:v1"
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
