# frozen_string_literal: true

require "securerandom"

module Igniter
  module Store
    module Protocol
      # OP3 — Wire Envelope: process boundary routing for StoreServer.
      #
      # Every request is wrapped in:
      #   { protocol: :igniter_store, schema_version: 1,
      #     request_id: "req_...", op: :write_fact,
      #     packet: { kind: :fact, store: :tasks, key: "t1", value: {} } }
      #
      # Every response is:
      #   { protocol: :igniter_store, schema_version: 1,
      #     request_id: "req_...",
      #     status: :ok | :error,
      #     result: { ... } | error: "message" }
      #
      # This layer sits above the CRC32-framed WireProtocol transport and below
      # application-level handlers.  It is pure Ruby — no I/O, no sockets.
      # The StoreServer feeds deserialized hashes in and ships serialized responses out.
      class WireEnvelope
        PROTOCOL        = :igniter_store
        SCHEMA_VERSION  = 1

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

        def initialize(interpreter)
          @interpreter = interpreter
        end

        # Dispatch a single envelope hash.
        # Returns a response envelope hash (never raises).
        def dispatch(envelope)
          envelope  = envelope.transform_keys(&:to_sym)
          req_id    = envelope[:request_id]

          proto = envelope[:protocol]&.to_sym
          unless proto == PROTOCOL
            return error_response(req_id, "Unknown protocol: #{proto.inspect}")
          end

          op = envelope[:op]&.to_sym
          unless op && OPERATIONS.include?(op)
            return error_response(req_id, "Unknown or missing op: #{op.inspect}")
          end

          packet = (envelope[:packet] || {})
          packet = packet.transform_keys(&:to_sym) if packet.is_a?(Hash)

          result = route(op, packet)
          ok_response(req_id, result)
        rescue => e
          error_response(req_id, "Internal error: #{e.message}")
        end

        private

        def route(op, packet)
          case op
          when :register_descriptor
            @interpreter.register(packet)

          when :write
            @interpreter.write(
              store:    packet.fetch(:store),
              key:      packet.fetch(:key),
              value:    packet.fetch(:value),
              producer: packet[:producer]
            )

          when :append
            @interpreter.append(
              history:        packet.fetch(:history),
              event:          packet.fetch(:event),
              key:            packet[:key],
              partition_key:  packet[:partition_key],
              schema_version: packet.fetch(:schema_version, 1),
              valid_time:     packet[:valid_time],
              term:           packet[:term],
              producer:       packet[:producer],
              derivation:     packet[:derivation]
            )

          when :write_fact
            @interpreter.write_fact(packet)

          when :read
            value = @interpreter.read(
              store: packet.fetch(:store),
              key:   packet.fetch(:key),
              as_of: packet[:as_of]
            )
            { value: value, found: !value.nil? }

          when :query
            items = @interpreter.query(
              store:  packet.fetch(:store),
              where:  packet.fetch(:where, {}),
              order:  packet[:order],
              limit:  packet[:limit],
              as_of:  packet[:as_of]
            )
            { items: items, results: items.map { |item| item[:value] }, count: items.size }

          when :resolve
            items = @interpreter.resolve_items(
              packet.fetch(:relation).to_sym,
              from:  packet.fetch(:from),
              as_of: packet[:as_of]
            )
            { items: items, results: items.map { |item| item[:value] }, count: items.size }

          when :causation_chain
            chain = @interpreter.causation_chain(
              store: packet.fetch(:store),
              key:   packet.fetch(:key)
            )
            { chain: chain, count: chain.size }

          when :lineage
            @interpreter.lineage(
              store: packet.fetch(:store),
              key:   packet.fetch(:key)
            )

          when :fact_ref
            ref = @interpreter.fact_ref(packet.fetch(:fact_id))
            { found: !ref.nil?, ref: ref }

          when :metadata_snapshot
            @interpreter.metadata_snapshot

          when :descriptor_snapshot
            @interpreter.descriptor_snapshot

          when :observability_snapshot
            @interpreter.observability_snapshot

          when :sync_hub_profile
            @interpreter.sync_hub_profile(
              as_of:  packet[:as_of],
              cursor: packet[:cursor],
              stores: packet[:stores]
            )

          when :replay
            facts = @interpreter.replay(
              from:   packet[:from],
              to:     packet[:to],
              filter: packet[:filter]
            )
            { facts: facts, count: facts.size }

          when :storage_stats
            @interpreter.storage_stats(store: packet[:store])

          when :segment_manifest
            @interpreter.segment_manifest(store: packet[:store])

          when :compaction_activity
            @interpreter.compaction_activity(
              store: packet[:store],
              kind:  packet[:kind],
              since: packet[:since],
              limit: packet[:limit]
            )
          end
        end

        def ok_response(request_id, result)
          {
            protocol:       PROTOCOL,
            schema_version: SCHEMA_VERSION,
            request_id:     request_id,
            status:         :ok,
            result:         result
          }
        end

        def error_response(request_id, message)
          {
            protocol:       PROTOCOL,
            schema_version: SCHEMA_VERSION,
            request_id:     request_id,
            status:         :error,
            error:          message
          }
        end
      end
    end
  end
end
