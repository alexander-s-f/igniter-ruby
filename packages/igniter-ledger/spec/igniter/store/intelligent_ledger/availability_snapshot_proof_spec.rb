# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_ledger"

# Intelligent Ledger — Availability Snapshot Proof
#
# Proves the first practical Intelligent Ledger use case: materialising an
# AvailabilitySnapshotFact for a Spark CRM technician from base facts.
#
# Seven acceptance scenarios:
#   1. Template-only: 5 days × 8h = 40h total
#   2. Override blocks a slot (partial overlap reduces available hours)
#   3. Order reservation blocks a slot
#   4. Cancellation restores a slot (cancelled order → interval restored)
#   5. Recompute writes new snapshot fact with different content
#   6. derived_from_fact_ids contains all contributing source fact IDs
#   7. Receipt references snapshot_fact_id and correct derivation_version
RSpec.describe "Intelligent Ledger: AvailabilitySnapshot proof" do
  IntelligentLedger = Igniter::Store::IntelligentLedger

  # Monday 2026-05-04 — start of a clean Mon-Fri week
  MONDAY = Date.new(2026, 5, 4)
  HORIZON_DAYS = 5

  # Mon-Fri 09:00–17:00 UTC template (8h/day)
  WEEKDAY_SCHEDULE = {
    "1" => [["09:00", "17:00"]],   # Mon
    "2" => [["09:00", "17:00"]],   # Tue
    "3" => [["09:00", "17:00"]],   # Wed
    "4" => [["09:00", "17:00"]],   # Thu
    "5" => [["09:00", "17:00"]]    # Fri
  }.freeze

  def monday_ts(hour, min = 0)
    Time.utc(2026, 5, 4, hour, min, 0).to_f
  end

  def tuesday_ts(hour, min = 0)
    Time.utc(2026, 5, 5, hour, min, 0).to_f
  end

  subject(:store) { Igniter::Store::IgniterStore.new }

  let(:ledger) { IntelligentLedger::AvailabilityLedger.new(store: store) }

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: template-only availability → 5 days × 8h = 40h total" do
    it "computes 144_000 available seconds (40h)" do
      ledger.write_template(technician_id: "tech-1", weekly_schedule: WEEKDAY_SCHEDULE)

      result = ledger.compute_snapshot(
        technician_id: "tech-1",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap = result[:snapshot_fact]
      expect(snap).not_to be_nil
      expect(snap.value[:available_seconds]).to eq(40 * 3600)
      expect(snap.value[:blocked_intervals]).to be_empty
      expect(snap.value[:available_slots].size).to eq(5)
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: override blocks a slot (partial overlap)" do
    it "reduces available hours by the blocked interval" do
      ledger.write_template(technician_id: "tech-2", weekly_schedule: WEEKDAY_SCHEDULE)
      # Block Monday 10:00–12:00 (2h)
      ledger.write_override(
        technician_id: "tech-2",
        override_id:   "ov-1",
        start_time:    monday_ts(10),
        end_time:      monday_ts(12)
      )

      result = ledger.compute_snapshot(
        technician_id: "tech-2",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap = result[:snapshot_fact]
      # 40h - 2h = 38h
      expect(snap.value[:available_seconds]).to eq(38 * 3600)
      expect(snap.value[:blocked_intervals].size).to eq(1)
      block = snap.value[:blocked_intervals].first
      expect(block[:start]).to eq(monday_ts(10))
      expect(block[:end]).to eq(monday_ts(12))
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: order reservation blocks a slot" do
    it "reduces available hours by the reserved interval" do
      ledger.write_template(technician_id: "tech-3", weekly_schedule: WEEKDAY_SCHEDULE)
      # Reserve Tuesday 14:00–15:30 (1.5h)
      ledger.write_order_event(
        order_id:      "order-100",
        technician_id: "tech-3",
        start_time:    tuesday_ts(14),
        end_time:      tuesday_ts(15, 30),
        type:          "reserved"
      )

      result = ledger.compute_snapshot(
        technician_id: "tech-3",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap = result[:snapshot_fact]
      # 40h - 1.5h = 38.5h = 138_600s
      expect(snap.value[:available_seconds]).to eq(38 * 3600 + 1800)
      expect(snap.value[:blocked_intervals].size).to eq(1)
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: cancellation restores a slot" do
    it "does not reduce availability when latest order event is 'cancelled'" do
      ledger.write_template(technician_id: "tech-4", weekly_schedule: WEEKDAY_SCHEDULE)

      # First: reserve Tuesday 09:00–11:00
      ledger.write_order_event(
        order_id:      "order-200",
        technician_id: "tech-4",
        start_time:    tuesday_ts(9),
        end_time:      tuesday_ts(11),
        type:          "reserved"
      )

      # Then: cancel the same order
      ledger.write_order_event(
        order_id:      "order-200",
        technician_id: "tech-4",
        start_time:    tuesday_ts(9),
        end_time:      tuesday_ts(11),
        type:          "cancelled"
      )

      result = ledger.compute_snapshot(
        technician_id: "tech-4",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap = result[:snapshot_fact]
      # Cancellation restores → full 40h
      expect(snap.value[:available_seconds]).to eq(40 * 3600)
      expect(snap.value[:blocked_intervals]).to be_empty
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: recompute after new facts writes a new snapshot fact" do
    it "second compute_snapshot produces a different snapshot fact with updated content" do
      ledger.write_template(technician_id: "tech-5", weekly_schedule: WEEKDAY_SCHEDULE)

      r1 = ledger.compute_snapshot(
        technician_id: "tech-5",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      # Add an override between the two derives
      ledger.write_override(
        technician_id: "tech-5",
        override_id:   "ov-new",
        start_time:    monday_ts(13),
        end_time:      monday_ts(14)
      )

      r2 = ledger.compute_snapshot(
        technician_id: "tech-5",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap1 = r1[:snapshot_fact]
      snap2 = r2[:snapshot_fact]

      expect(snap2.id).not_to eq(snap1.id)
      expect(snap2.value[:available_seconds]).to eq(snap1.value[:available_seconds] - 3600)
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: derived_from_fact_ids contains all source fact IDs" do
    it "includes template fact id, override fact ids, and order event fact ids" do
      tmpl_fact = ledger.write_template(
        technician_id: "tech-6",
        weekly_schedule: WEEKDAY_SCHEDULE
      )

      ov_fact = ledger.write_override(
        technician_id: "tech-6",
        override_id:   "ov-a",
        start_time:    monday_ts(10),
        end_time:      monday_ts(11)
      )

      ord_fact = ledger.write_order_event(
        order_id:      "order-300",
        technician_id: "tech-6",
        start_time:    tuesday_ts(9),
        end_time:      tuesday_ts(10),
        type:          "reserved"
      )

      result = ledger.compute_snapshot(
        technician_id: "tech-6",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      ids = result[:snapshot_fact].value[:derived_from_fact_ids]
      expect(ids).to include(tmpl_fact.id)
      expect(ids).to include(ov_fact.id)
      expect(ids).to include(ord_fact.id)
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: receipt references snapshot_fact_id and derivation_version" do
    it "persists a derivation receipt linked to the snapshot fact" do
      ledger.write_template(technician_id: "tech-7", weekly_schedule: WEEKDAY_SCHEDULE)

      result = ledger.compute_snapshot(
        technician_id: "tech-7",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snap    = result[:snapshot_fact]
      receipt = result[:receipt_fact]

      expect(receipt).not_to be_nil
      expect(receipt.value[:snapshot_fact_id]).to eq(snap.id)
      expect(receipt.value[:derivation_version]).to eq(
        Igniter::Store::IntelligentLedger::AvailabilityDeriver::DERIVATION_VERSION
      )
      expect(receipt.value[:derivation_name]).to eq(
        Igniter::Store::IntelligentLedger::AvailabilityDeriver::DERIVATION_NAME
      )
      expect(receipt.key).to eq(snap.id)

      # Receipt is readable by snapshot_fact_id
      stored_receipt = ledger.read_receipt(snap.id)
      expect(stored_receipt).not_to be_nil
      expect(stored_receipt.value[:snapshot_fact_id]).to eq(snap.id)
    end

    it "persists inline derivation metadata on the snapshot fact" do
      ledger.write_template(technician_id: "tech-7b", weekly_schedule: WEEKDAY_SCHEDULE)

      result = ledger.compute_snapshot(
        technician_id: "tech-7b",
        horizon_start: MONDAY,
        horizon_days:  HORIZON_DAYS
      )

      snapshot = result[:snapshot_fact]
      expect(snapshot.derivation[:name]).to eq(
        Igniter::Store::IntelligentLedger::AvailabilityDeriver::DERIVATION_NAME
      )
      expect(snapshot.derivation[:version]).to eq(
        Igniter::Store::IntelligentLedger::AvailabilityDeriver::DERIVATION_VERSION
      )
      expect(snapshot.derivation[:source_fact_ids]).not_to be_empty
    end
  end
end
