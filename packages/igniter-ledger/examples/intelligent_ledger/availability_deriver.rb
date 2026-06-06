# frozen_string_literal: true

require "time"
require "date"

module Igniter
  module Store
    module IntelligentLedger
      # Pure computation: derives an AvailabilitySnapshot from base facts.
      # No store dependency — all IO lives in AvailabilityLedger.
      #
      # Template format (value Hash):
      #   { "weekly_schedule" => { "1" => [["09:00","17:00"]], "3" => [...], ... } }
      #   Keys are wday strings ("0"=Sun … "6"=Sat); values are arrays of [start_time, end_time].
      #
      # Override/reservation value:
      #   { "start" => <unix float>, "end" => <unix float>, "type" => "block"|"reserve"|"cancel",
      #     "order_id" => "..." (optional) }
      class AvailabilityDeriver
        DERIVATION_NAME    = "availability_snapshot"
        DERIVATION_VERSION = "1.0"

        # Returns a value Hash suitable for storing as an AvailabilitySnapshotFact.
        #
        # base_facts:
        #   :template            — Fact or nil (weekly schedule)
        #   :overrides           — Array<Fact> (explicit time blocks)
        #   :active_reservations — Array<Fact> (reserved order slots)
        #
        # horizon_start    — Date (inclusive, start of window)
        # horizon_days     — Integer (number of days to expand)
        # source_fact_ids  — Array<String> (all fact IDs that contributed)
        # source_fact_refs — Array<Hash>   (structured refs: id/store/role; optional)
        def derive(base_facts:, horizon_start:, horizon_days:, source_fact_ids:, source_fact_refs: nil)
          template_value    = base_facts[:template]&.value || {}
          override_facts    = base_facts[:overrides] || []
          reservation_facts = base_facts[:active_reservations] || []

          # 1. Expand template into intervals over the horizon window
          available = expand_template(template_value, horizon_start, horizon_days)

          # 2. Collect blocking intervals (overrides + reservations)
          blocked = collect_blocked(override_facts, reservation_facts)

          # 3. Subtract blocked from available
          blocked.each { |b| available = subtract_interval(available, b) }

          # 4. Compute total available seconds
          available_seconds = available.sum { |s, e| e - s }

          refs = (source_fact_refs || []).uniq { |r| r["id"] || r[:id] }

          {
            "available_slots"        => available.map { |s, e| { "start" => s, "end" => e } },
            "blocked_intervals"      => blocked.map { |s, e| { "start" => s, "end" => e } },
            "available_seconds"      => available_seconds.round,
            "derived_from_fact_ids"  => source_fact_ids.uniq,
            "derived_from_fact_refs" => refs,
            "derivation"             => {
              "name"    => DERIVATION_NAME,
              "version" => DERIVATION_VERSION
            },
            "computed_at"            => Time.now.iso8601(3),
            "horizon_start"          => horizon_start.iso8601,
            "horizon_days"           => horizon_days
          }
        end

        private

        # Expands the weekly_schedule template into concrete [start_ts, end_ts] pairs
        # over [horizon_start, horizon_start + horizon_days).
        # Fact values have symbol keys (native extension normalises all keys to symbols).
        def expand_template(template_value, horizon_start, horizon_days)
          schedule = template_value[:weekly_schedule] || {}
          intervals = []

          horizon_days.times do |offset|
            day = horizon_start + offset
            wday_sym   = day.wday.to_s.to_sym
            wday_slots = schedule[wday_sym] || []
            wday_slots.each do |slot|
              start_ts = day_time_to_unix(day, slot[0].to_s)
              end_ts   = day_time_to_unix(day, slot[1].to_s)
              intervals << [start_ts, end_ts] if end_ts > start_ts
            end
          end

          intervals.sort_by(&:first)
        end

        # Gathers blocking intervals from override and reservation facts.
        # Ignores facts whose type is "cancel" (cancellations restore availability).
        def collect_blocked(override_facts, reservation_facts)
          blocked = []

          override_facts.each do |f|
            v = f.value
            next if v[:type].to_s == "cancel"
            s = v[:start].to_f
            e = v[:end].to_f
            blocked << [s, e] if e > s
          end

          reservation_facts.each do |f|
            v = f.value
            next if v[:type].to_s == "cancel"
            s = v[:start].to_f
            e = v[:end].to_f
            blocked << [s, e] if e > s
          end

          blocked.sort_by(&:first)
        end

        # Subtracts one [block_start, block_end] interval from a list of [start, end] pairs.
        # Handles: no-overlap, full-containment, left-trim, right-trim, split.
        def subtract_interval(intervals, block)
          bs, be = block
          result = []
          intervals.each do |s, e|
            if be <= s || bs >= e
              # no overlap — keep as-is
              result << [s, e]
            elsif bs <= s && be >= e
              # block fully covers slot — drop
            elsif bs > s && be < e
              # block splits slot — keep left and right fragments
              result << [s, bs]
              result << [be, e]
            elsif bs <= s
              # block trims left side
              result << [be, e] if be < e
            else
              # block trims right side
              result << [s, bs] if bs > s
            end
          end
          result
        end

        # Converts a Date + "HH:MM" string to a Unix timestamp (Float).
        def day_time_to_unix(date, time_str)
          h, m = time_str.split(":").map(&:to_i)
          Time.utc(date.year, date.month, date.day, h, m, 0).to_f
        end
      end
    end
  end
end
