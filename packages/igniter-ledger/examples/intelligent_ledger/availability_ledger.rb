# frozen_string_literal: true

require_relative "availability_deriver"

module Igniter
  module Store
    module IntelligentLedger
      # Store-backed orchestrator for the AvailabilitySnapshot derivation.
      #
      # Reads base facts from an IgniterStore, invokes AvailabilityDeriver,
      # then persists the snapshot fact and a derivation receipt.
      #
      # Store layout:
      #   :availability_templates  — key: technician_id
      #   :availability_overrides  — key: "technician_id/override_id"
      #   :order_events            — key: order_id (value has "type": "reserved"/"cancelled")
      #   :availability_snapshots  — key: "technician_id/horizon_bucket"
      #   :derivation_receipts     — key: snapshot_fact_id
      class AvailabilityLedger
        PRODUCER = { "system" => "availability_ledger", "version" => AvailabilityDeriver::DERIVATION_VERSION }.freeze

        def initialize(store:)
          @store   = store
          @deriver = AvailabilityDeriver.new
        end

        # Writes a template fact for a technician.
        # weekly_schedule: { "1" => [["09:00","17:00"]], ... }
        def write_template(technician_id:, weekly_schedule:)
          @store.write(
            store: :availability_templates,
            key:   technician_id.to_s,
            value: { "weekly_schedule" => weekly_schedule }
          )
        end

        # Writes an override fact (block a specific interval).
        # type: "block" (default) or "cancel"
        def write_override(technician_id:, override_id:, start_time:, end_time:, type: "block")
          @store.write(
            store: :availability_overrides,
            key:   "#{technician_id}/#{override_id}",
            value: {
              "technician_id" => technician_id.to_s,
              "start"         => start_time.to_f,
              "end"           => end_time.to_f,
              "type"          => type
            }
          )
        end

        # Writes an order event fact.
        # type: "reserved" or "cancelled"
        def write_order_event(order_id:, technician_id:, start_time:, end_time:, type: "reserved")
          @store.write(
            store: :order_events,
            key:   order_id.to_s,
            value: {
              "order_id"      => order_id.to_s,
              "technician_id" => technician_id.to_s,
              "start"         => start_time.to_f,
              "end"           => end_time.to_f,
              "type"          => type
            }
          )
        end

        # Derives and persists an availability snapshot for a technician over a horizon window.
        #
        # horizon_start — Date (inclusive)
        # horizon_days  — Integer (window length)
        #
        # Returns { snapshot_fact:, receipt_fact: }.
        def compute_snapshot(technician_id:, horizon_start:, horizon_days:)
          tid = technician_id.to_s

          # --- gather base facts ---
          template_fact = @store.history(store: :availability_templates, key: tid).last

          override_facts = @store.history(store: :availability_overrides).select do |f|
            f.key.start_with?("#{tid}/")
          end

          order_facts = @store.history(store: :order_events).select do |f|
            f.value[:technician_id].to_s == tid
          end

          # Active reservations = latest event per order_id where type != "cancelled"
          active_reservations = active_order_facts(order_facts)

          # Collect source fact IDs and structured refs (id + store + role).
          source_ids  = []
          source_refs = []

          if template_fact
            source_ids  << template_fact.id
            source_refs << { "id" => template_fact.id, "store" => "availability_templates",
                             "role" => "template", "key" => template_fact.key }
          end

          override_facts.each do |f|
            source_ids  << f.id
            source_refs << { "id" => f.id, "store" => "availability_overrides",
                             "role" => "override", "key" => f.key }
          end

          order_facts.each do |f|
            source_ids  << f.id
            source_refs << { "id" => f.id, "store" => "order_events",
                             "role" => "order_event", "key" => f.key }
          end

          base_facts = {
            template:            template_fact,
            overrides:           override_facts,
            active_reservations: active_reservations
          }

          # --- derive ---
          snapshot_value = @deriver.derive(
            base_facts:       base_facts,
            horizon_start:    horizon_start,
            horizon_days:     horizon_days,
            source_fact_ids:  source_ids,
            source_fact_refs: source_refs
          )

          # --- persist snapshot ---
          bucket = "#{horizon_start.iso8601}/#{horizon_days}d"
          snapshot_fact = @store.write(
            store:    :availability_snapshots,
            key:      "#{tid}/#{bucket}",
            value:    snapshot_value,
            producer: PRODUCER,
            derivation: snapshot_derivation_metadata(snapshot_value)
          )

          # --- persist receipt ---
          receipt_value = {
            "snapshot_fact_id"   => snapshot_fact.id,
            "technician_id"      => tid,
            "horizon_start"      => horizon_start.iso8601,
            "horizon_days"       => horizon_days,
            "derivation_name"    => AvailabilityDeriver::DERIVATION_NAME,
            "derivation_version" => AvailabilityDeriver::DERIVATION_VERSION,
            "source_fact_ids"    => source_ids.uniq,
            "source_fact_refs"   => source_refs.uniq { |r| r["id"] },
            "derived_at"         => Time.now.iso8601(3)
          }

          receipt_fact = @store.write(
            store:    :derivation_receipts,
            key:      snapshot_fact.id,
            value:    receipt_value,
            producer: PRODUCER
          )

          { snapshot_fact: snapshot_fact, receipt_fact: receipt_fact }
        end

        # Reads the latest snapshot Fact for a technician/horizon combination.
        # Returns nil if none exists.
        def read_snapshot(technician_id:, horizon_start:, horizon_days:)
          bucket = "#{horizon_start.iso8601}/#{horizon_days}d"
          @store.history(store: :availability_snapshots, key: "#{technician_id}/#{bucket}").last
        end

        # Reads the derivation receipt Fact for a given snapshot_fact_id.
        def read_receipt(snapshot_fact_id)
          @store.history(store: :derivation_receipts, key: snapshot_fact_id).last
        end

        private

        # From a list of order event facts, return only the facts that represent
        # the latest state per order_id and are NOT cancelled.
        def active_order_facts(order_facts)
          by_order = order_facts.group_by { |f| f.key }
          by_order.filter_map do |_order_id, facts|
            latest = facts.max_by(&:transaction_time)
            latest if latest&.value&.fetch(:type, nil).to_s != "cancelled"
          end
        end

        def snapshot_derivation_metadata(snapshot_value)
          raw = snapshot_value.fetch("derivation")
          {
            name:             raw.fetch("name"),
            version:          raw.fetch("version"),
            source_fact_ids:  snapshot_value.fetch("derived_from_fact_ids"),
            source_fact_refs: snapshot_value.fetch("derived_from_fact_refs", [])
          }
        end
      end
    end
  end
end
