# frozen_string_literal: true

module Igniter
  module Store
    module Protocol
      # OP4 — Sync Hub Profile value object.
      #
      # A SyncProfile is a point-in-time package that carries everything a durable
      # hub needs to synchronize with the live store:
      #
      #   descriptors             — full metadata_snapshot (OP2)
      #   facts                   — serialized fact packets (full or incremental)
      #   retention               — retention policy snapshot
      #   compaction_receipts     — compaction history
      #   cursor                  — watermark for next incremental sync
      #   subscription_checkpoints — last-delivered position per subscription (OP4+)
      #
      # Cursor:
      #   nil        — this is a fresh full snapshot (hub has never synced)
      #   { kind: :timestamp, value: Float } — resume from this timestamp
      #
      # A hub stores the cursor locally.  On the next sync request it sends
      # cursor: back and receives only facts written since that timestamp.
      SyncProfile = Struct.new(
        :schema_version,
        :kind,
        :generated_at,              # Float (CLOCK_REALTIME)
        :cursor,                    # { kind: :timestamp, value: Float } | nil
        :descriptors,               # Hash — from Protocol::Interpreter#metadata_snapshot
        :facts,                     # Array<Hash> — serialized fact packets
        :retention,                 # Hash — from SchemaGraph#retention_snapshot
        :compaction_receipts,       # Array<Hash> — compaction summaries
        :compaction_activity,       # Hash — normalized activity envelope from Interpreter#compaction_activity
        :subscription_checkpoints,  # Hash — subscription name → last position
        keyword_init: true
      ) do
        def full?        = cursor.nil?
        def incremental? = !full?
        def fact_count   = facts.size

        def to_json(*opts) = to_h.to_json(*opts)

        # Build the cursor that a hub should send on its next sync request.
        def next_cursor
          return nil if facts.empty?
          latest_ts = facts.max_by { |f| f[:transaction_time] || f[:timestamp] }
                          .then { |f| f[:transaction_time] || f[:timestamp] }
          { kind: :timestamp, value: latest_ts }
        end
      end
    end
  end
end
