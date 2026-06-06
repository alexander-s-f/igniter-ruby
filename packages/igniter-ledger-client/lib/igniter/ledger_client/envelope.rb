# frozen_string_literal: true

require "securerandom"

module Igniter
  module LedgerClient
    module Envelope
      PROTOCOL = :igniter_store
      SCHEMA_VERSION = 1

      OPERATIONS = %i[
        register_descriptor
        write
        append
        write_fact
        read
        query
        resolve
        causation_chain
        lineage
        fact_ref
        metadata_snapshot
        descriptor_snapshot
        observability_snapshot
        sync_hub_profile
        replay
        storage_stats
        segment_manifest
        compaction_activity
      ].freeze

      module_function

      def request(operation:, packet: {}, request_id: nil)
        operation = operation.to_sym
        raise ArgumentError, "unknown ledger op: #{operation.inspect}" unless OPERATIONS.include?(operation)

        {
          protocol: PROTOCOL,
          schema_version: SCHEMA_VERSION,
          request_id: request_id || generate_request_id,
          op: operation,
          packet: packet || {}
        }
      end

      def ok?(response)
        normalize(response)[:status]&.to_sym == :ok
      end

      def result_or_raise(response)
        response = normalize(response)
        return response[:result] if ok?(response)

        raise Error.new(
          response[:error] || "ledger client request failed",
          response: response,
          request_id: response[:request_id]
        )
      end

      def normalize(hash)
        hash.to_h.transform_keys(&:to_sym)
      end

      def generate_request_id
        "req_#{SecureRandom.hex(12)}"
      end
    end
  end
end
