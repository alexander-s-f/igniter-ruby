# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

# Intelligent Ledger — LedgerBoundary Settlement Proof
#
# Extends the availability boundary proof with a pre-compaction settlement stage.
#
# Research question:
#   Before a boundary loses internal detail, can it materialise useful long-lived
#   memory as summaries, reports, metrics, and settlement receipts?
#
#   Scenario 1:  settle_boundary persists summary, metrics, and settlement receipt
#   Scenario 2:  closed-but-unsettled boundary cannot compact
#   Scenario 3:  settled boundary can compact
#   Scenario 4:  compaction receipt references the settlement receipt
#   Scenario 5:  cleanup plan blocked for unsettled boundary (:settlement_required)
#   Scenario 6:  cleanup plan ready after settlement
#   Scenario 7:  boundary replay works after settlement and after compaction
#   Scenario 8:  full replay reports :detail_unavailable after settlement+compaction
#   Scenario 9:  late facts after settlement record settlement_status_at_arrival
#   Scenario 10: late facts after compaction record both statuses; original hash unchanged
IntelligentLedger = Igniter::Store::IntelligentLedger unless defined?(IntelligentLedger)

RSpec.describe "Intelligent Ledger: LedgerBoundary settlement proof" do
  SETTLEMENT_DATE     = Date.new(2026, 5, 4)
  SETTLEMENT_SCHEDULE = {
    "1" => [["09:00", "17:00"]],
    "2" => [["09:00", "17:00"]],
    "3" => [["09:00", "17:00"]],
    "4" => [["09:00", "17:00"]],
    "5" => [["09:00", "17:00"]]
  }.freeze

  subject(:store) { Igniter::Store::IgniterStore.new }
  let(:ledger)    { IntelligentLedger::AvailabilityBoundaryLedger.new(store: store) }
  let(:company)   { "company-settle" }

  # Helpers ──────────────────────────────────────────────────────────────────

  def setup_closed_boundary(tid, schedule: SETTLEMENT_SCHEDULE, horizon_days: 1)
    ledger.write_template(technician_id: tid, weekly_schedule: schedule)
    ledger.open_boundary(company_id: company, technician_id: tid, date: SETTLEMENT_DATE)
    r = ledger.close_boundary(company_id: company, technician_id: tid, date: SETTLEMENT_DATE,
                              horizon_days: horizon_days)
    r[:boundary].boundary_key
  end

  def boundary_key_for(tid)
    IntelligentLedger::LedgerBoundary.key_for(
      company_id: company, technician_id: tid, date: SETTLEMENT_DATE.to_s
    )
  end

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: settle_boundary persists summary, metrics, and settlement receipt" do
    let(:tid) { "tech-settle-s1" }
    let!(:bk) { setup_closed_boundary(tid) }

    subject(:settle_result) { ledger.settle_boundary(bk) }

    it "returns :settled boundary" do
      expect(settle_result[:boundary].settled?).to be true
      expect(settle_result[:boundary].settlement_status).to eq(:settled)
    end

    it "writes availability summary to :ledger_boundary_summaries" do
      settle_result
      fact = store.history(store: :ledger_boundary_summaries, key: bk).last
      expect(fact).not_to be_nil
      expect(fact.value[:summary_type]).to eq("availability")
      expect(fact.value[:available_seconds]).to eq(8 * 3600)
      expect(fact.value[:available_slot_count]).to eq(1)
      expect(fact.value[:blocked_interval_count]).to eq(0)
      expect(fact.value[:result_hash]).to eq(ledger.find_boundary(bk).result_hash)
    end

    it "summary includes source_fact_count" do
      settle_result
      fact = store.history(store: :ledger_boundary_summaries, key: bk).last
      expect(fact.value[:source_fact_count]).to be > 0
    end

    it "writes capacity metrics to :ledger_boundary_metrics" do
      settle_result
      fact = store.history(store: :ledger_boundary_metrics, key: bk).last
      expect(fact).not_to be_nil
      # 8h / 24h * 100 = 33.33%
      expect(fact.value[:capacity_percent]).to eq(33.33)
      expect(fact.value[:available_hours]).to eq(8.0)
      expect(fact.value[:blocked_hours]).to eq(0.0)
    end

    it "writes settlement receipt to :ledger_settlement_receipts" do
      settle_result
      fact = store.history(store: :ledger_settlement_receipts, key: bk).last
      expect(fact).not_to be_nil
      expect(fact.value[:settlement_status]).to eq("settled")
      expect(fact.value[:boundary_key]).to eq(bk)
      expect(fact.value[:result_hash]).to eq(ledger.find_boundary(bk).result_hash)
    end

    it "settlement receipt lists transform names" do
      settle_result
      fact = store.history(store: :ledger_settlement_receipts, key: bk).last
      expect(fact.value[:transform_names]).to include("availability_summary", "availability_metrics")
    end

    it "settlement receipt includes output_fact_ids for each transform" do
      r    = settle_result
      fact = store.history(store: :ledger_settlement_receipts, key: bk).last
      ids  = fact.value[:output_fact_ids]
      expect(ids[:availability_summary]).to eq(r[:summary_fact].id)
      expect(ids[:availability_metrics]).to eq(r[:metrics_fact].id)
    end

    it "settlement receipt embeds per-transform receipts" do
      settle_result
      fact       = store.history(store: :ledger_settlement_receipts, key: bk).last
      transforms = fact.value[:transforms]
      expect(transforms).to be_an(Array)
      expect(transforms.size).to eq(2)
      # Store normalises string keys to symbols on read-back
      names = transforms.map { |t| t[:transform_name] }
      expect(names).to include("availability_summary", "availability_metrics")
      transforms.each do |t|
        expect(t[:input_result_hash]).to eq(ledger.find_boundary(bk).result_hash)
        expect(t[:status]).to eq("ok")
      end
    end

    it "boundary stores the settlement_receipt_id" do
      r = settle_result
      expect(r[:boundary].settlement_receipt_id).to eq(r[:settlement_receipt].id)
    end

    it "metrics reflect blocked intervals when overrides exist" do
      tid2 = "tech-settle-s1b"
      ledger.write_template(technician_id: tid2, weekly_schedule: SETTLEMENT_SCHEDULE)
      # Block 09:00–10:00 on Monday
      ledger.write_override(
        technician_id: tid2, override_id: "ov-1",
        start_time: Time.utc(2026, 5, 4, 9, 0, 0).to_f,
        end_time:   Time.utc(2026, 5, 4, 10, 0, 0).to_f
      )
      ledger.open_boundary(company_id: company, technician_id: tid2, date: SETTLEMENT_DATE)
      r2 = ledger.close_boundary(company_id: company, technician_id: tid2, date: SETTLEMENT_DATE)
      bk2 = r2[:boundary].boundary_key
      ledger.settle_boundary(bk2)

      metrics = store.history(store: :ledger_boundary_metrics, key: bk2).last
      expect(metrics.value[:blocked_hours]).to eq(1.0)
      expect(metrics.value[:available_hours]).to eq(7.0)
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: closed-but-unsettled boundary cannot compact" do
    let(:tid) { "tech-settle-s2" }
    let!(:bk) { setup_closed_boundary(tid) }

    it "raises ArgumentError when compact is attempted before settlement" do
      expect { ledger.compact_boundary(bk) }
        .to raise_error(ArgumentError, /must be settled/)
    end

    it "boundary remains :closed after a failed compact attempt" do
      begin
        ledger.compact_boundary(bk)
      rescue ArgumentError
        nil
      end
      expect(ledger.find_boundary(bk).status).to eq(:closed)
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: settled boundary can compact" do
    let(:tid) { "tech-settle-s3" }
    let!(:bk) { setup_closed_boundary(tid) }

    before { ledger.settle_boundary(bk) }

    it "compact_boundary succeeds after settlement" do
      expect { ledger.compact_boundary(bk) }.not_to raise_error
    end

    it "boundary transitions to :compacted after settle + compact" do
      ledger.compact_boundary(bk)
      expect(ledger.find_boundary(bk).status).to eq(:compacted)
      expect(ledger.find_boundary(bk).detail_status).to eq(:purged)
    end

    it "result_hash is unchanged after settle + compact" do
      pre_hash = ledger.find_boundary(bk).result_hash
      ledger.compact_boundary(bk)
      expect(ledger.find_boundary(bk).result_hash).to eq(pre_hash)
    end

    it "settlement_status remains :settled after compaction" do
      ledger.compact_boundary(bk)
      expect(ledger.find_boundary(bk).settlement_status).to eq(:settled)
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: compaction receipt references the settlement receipt" do
    let(:tid) { "tech-settle-s4" }
    let!(:bk) { setup_closed_boundary(tid) }

    before do
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
    end

    it "cleanup receipt includes settlement_receipt_id" do
      stored = store.history(store: :ledger_cleanup_receipts, key: bk).last
      expect(stored).not_to be_nil
      expect(stored.value[:settlement_receipt_id]).not_to be_nil
    end

    it "settlement_receipt_id in cleanup receipt matches boundary's settlement_receipt_id" do
      boundary = ledger.find_boundary(bk)
      stored   = store.history(store: :ledger_cleanup_receipts, key: bk).last
      expect(stored.value[:settlement_receipt_id]).to eq(boundary.settlement_receipt_id)
    end

    it "settlement outputs remain readable in :ledger_settlement_receipts after compaction" do
      receipt = store.history(store: :ledger_settlement_receipts, key: bk).last
      expect(receipt).not_to be_nil
      expect(receipt.value[:settlement_status]).to eq("settled")
    end

    it "summary output remains readable in :ledger_boundary_summaries after compaction" do
      summary = store.history(store: :ledger_boundary_summaries, key: bk).last
      expect(summary).not_to be_nil
      expect(summary.value[:available_seconds]).to eq(8 * 3600)
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: cleanup plan blocked for unsettled boundary (:settlement_required)" do
    let(:tid)    { "tech-settle-s5" }
    let(:cutoff) { Time.utc(2026, 5, 5, 0, 0, 0) }

    before { setup_closed_boundary(tid) }

    it "plan is :blocked when boundary is closed but not settled" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:status]).to eq(:blocked)
    end

    it "blocking_reasons maps the boundary key to :settlement_required" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:blocking_reasons][boundary_key_for(tid)]).to eq(:settlement_required)
    end

    it "blocking_boundaries includes the unsettled boundary key" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:blocking_boundaries]).to include(boundary_key_for(tid))
    end

    it "blocking_reasons maps open boundary key to :open" do
      open_tid = "tech-settle-s5-open"
      ledger.write_template(technician_id: open_tid, weekly_schedule: SETTLEMENT_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: open_tid, date: SETTLEMENT_DATE)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:blocking_reasons][boundary_key_for(open_tid)]).to eq(:open)
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: cleanup plan ready after settlement" do
    let(:tid)    { "tech-settle-s6" }
    let(:cutoff) { Time.utc(2026, 5, 5, 0, 0, 0) }

    before do
      bk = setup_closed_boundary(tid)
      ledger.settle_boundary(bk)
    end

    it "plan is :ready after settlement" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:status]).to eq(:ready)
    end

    it "no blocking boundaries in ready plan" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:blocking_boundaries]).to be_empty
    end

    it "ready plan includes boundary receipt IDs for retention" do
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:receipts_to_keep]).not_to be_empty
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: boundary replay works after settlement and after compaction" do
    let(:tid) { "tech-settle-s7" }
    let!(:bk) { setup_closed_boundary(tid) }

    it "replay returns :ok after settlement (detail_status still :full)" do
      ledger.settle_boundary(bk)
      result = ledger.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:boundary)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
      expect(result[:detail_status]).to eq(:full)
    end

    it "replay returns :ok after settlement + compaction (detail_status :purged)" do
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
      result = ledger.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:boundary)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
      expect(result[:detail_status]).to eq(:purged)
    end

    it "result_hash is the same across all replay calls after settle + compact" do
      boundary = ledger.find_boundary(bk)
      original = boundary.result_hash
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
      expect(ledger.replay(bk)[:result_hash]).to eq(original)
    end
  end

  # ── Scenario 8 ───────────────────────────────────────────────────────────────

  describe "Scenario 8: full replay reports :detail_unavailable after settlement + compaction" do
    let(:tid) { "tech-settle-s8" }
    let!(:bk) { setup_closed_boundary(tid) }

    before do
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
    end

    it "full_replay returns :detail_unavailable" do
      result = ledger.full_replay(company_id: company, technician_id: tid, date: SETTLEMENT_DATE)
      expect(result[:status]).to eq(:detail_unavailable)
      expect(result[:detail_status]).to eq(:purged)
    end

    it "full_replay includes boundary_receipt_id" do
      result = ledger.full_replay(company_id: company, technician_id: tid, date: SETTLEMENT_DATE)
      expect(result[:boundary_receipt_id]).not_to be_nil
    end

    it "settlement outputs remain readable even after full_replay returns unavailable" do
      ledger.full_replay(company_id: company, technician_id: tid, date: SETTLEMENT_DATE)
      summary = store.history(store: :ledger_boundary_summaries, key: bk).last
      expect(summary.value[:available_seconds]).to eq(8 * 3600)
    end
  end

  # ── Scenario 9 ───────────────────────────────────────────────────────────────

  describe "Scenario 9: late facts after settlement record settlement_status_at_arrival" do
    let(:tid) { "tech-settle-s9" }
    let!(:bk) { setup_closed_boundary(tid) }

    before { ledger.settle_boundary(bk) }

    it "late-fact receipt records settlement_status_at_arrival: 'settled'" do
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-settled" },
        fact_type:    :order_event
      )
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:settlement_status_at_arrival]).to eq("settled")
      expect(stored.value[:boundary_status_at_arrival]).to eq("closed")
    end

    it "original result_hash is unchanged after late fact" do
      original = ledger.find_boundary(bk).result_hash
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-settled-2" },
        fact_type:    :order_event
      )
      expect(ledger.find_boundary(bk).result_hash).to eq(original)
    end

    it "settlement outputs are unchanged after late fact" do
      summary_before = store.history(store: :ledger_boundary_summaries, key: bk).last
      avail_before   = summary_before.value[:available_seconds]

      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-settled-3" },
        fact_type:    :order_event
      )

      summary_after = store.history(store: :ledger_boundary_summaries, key: bk).last
      expect(summary_after.value[:available_seconds]).to eq(avail_before)
    end
  end

  # ── Scenario 10 ──────────────────────────────────────────────────────────────

  describe "Scenario 10: late facts after compaction record both statuses; original hash unchanged" do
    let(:tid) { "tech-settle-s10" }
    let!(:bk) { setup_closed_boundary(tid) }
    let(:original_hash) { ledger.find_boundary(bk).result_hash }

    before do
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
    end

    it "late-fact receipt records boundary_status_at_arrival: 'compacted'" do
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-compacted" },
        fact_type:    :order_event
      )
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:boundary_status_at_arrival]).to eq("compacted")
    end

    it "late-fact receipt records settlement_status_at_arrival: 'settled'" do
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-compacted-2" },
        fact_type:    :order_event
      )
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:settlement_status_at_arrival]).to eq("settled")
    end

    it "does not mutate original result_hash after late fact" do
      original = original_hash
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-compacted-3" },
        fact_type:    :order_event
      )
      expect(ledger.find_boundary(bk).result_hash).to eq(original)
    end

    it "boundary replay still returns correct output after late fact" do
      ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-compacted-4" },
        fact_type:    :order_event
      )
      result = ledger.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end
  end
end
