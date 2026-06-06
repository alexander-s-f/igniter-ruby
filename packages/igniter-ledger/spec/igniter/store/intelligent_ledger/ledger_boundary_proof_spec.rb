# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

# Intelligent Ledger — LedgerBoundary Availability Proof
#
# Proves the LedgerBoundary lifecycle over the technician availability example:
#
#   Scenario 1: open/close boundary lifecycle + deterministic key
#   Scenario 2: close writes output, receipt, and boundary record
#   Scenario 3: boundary replay returns closed output without full-history scan
#   Scenario 4: full replay works before compaction; reports :detail_unavailable after
#   Scenario 5: compaction writes cleanup receipt and marks detail_status :purged
#   Scenario 6: cleanup plan blocked by open boundary, ready after closure
#   Scenario 7: late fact creates correction evidence; original result_hash unchanged
#   Scenario 8: existing AvailabilityLedger delegation remains intact
IntelligentLedger = Igniter::Store::IntelligentLedger unless defined?(IntelligentLedger)

RSpec.describe "Intelligent Ledger: LedgerBoundary availability proof" do
  # Monday 2026-05-04 — same anchor as the existing snapshot proof
  BOUNDARY_PROOF_DATE = Date.new(2026, 5, 4)

  # Mon-Fri 09:00–17:00 UTC (8h/day)
  BOUNDARY_WEEKDAY_SCHEDULE = {
    "1" => [["09:00", "17:00"]],
    "2" => [["09:00", "17:00"]],
    "3" => [["09:00", "17:00"]],
    "4" => [["09:00", "17:00"]],
    "5" => [["09:00", "17:00"]]
  }.freeze

  def monday_ts(hour, min = 0)
    Time.utc(2026, 5, 4, hour, min, 0).to_f
  end

  subject(:store) { Igniter::Store::IgniterStore.new }
  let(:ledger)    { IntelligentLedger::AvailabilityBoundaryLedger.new(store: store) }
  let(:company)   { "company-1" }

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: open/close lifecycle + deterministic boundary key" do
    let(:tid) { "tech-s1" }

    it "open_boundary returns a boundary with status :open" do
      b = ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      expect(b.status).to eq(:open)
      expect(b.open?).to be true
    end

    it "boundary key is deterministic from subject" do
      b = ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      canonical = IntelligentLedger::LedgerBoundary.key_for(
        company_id:    company,
        technician_id: tid,
        date:          BOUNDARY_PROOF_DATE.to_s
      )
      expect(b.boundary_key).to eq(canonical)
    end

    it "boundary key encodes policy, subject, and version" do
      b = ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      expect(b.boundary_key).to include("technician_day")
      expect(b.boundary_key).to include("company=#{company}")
      expect(b.boundary_key).to include("technician=#{tid}")
      expect(b.boundary_key).to include("date=#{BOUNDARY_PROOF_DATE}")
      expect(b.boundary_key).to include("version=1.0")
    end

    it "close_boundary transitions to :closed with a SHA-256 result_hash" do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)

      result   = ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      boundary = result[:boundary]

      expect(boundary.status).to eq(:closed)
      expect(boundary.closed?).to be true
      expect(boundary.result_hash).to match(/\A[0-9a-f]{64}\z/)
    end

    it "result_hash does not change between replay calls on the same boundary" do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r = ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      hash_at_close = r[:boundary].result_hash
      # Replaying the boundary does not recompute or alter the hash
      expect(ledger.replay(r[:boundary].boundary_key)[:result_hash]).to eq(hash_at_close)
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: close writes output + receipt + boundary record" do
    let(:tid) { "tech-s2" }

    before do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
    end

    subject(:close_result) do
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
    end

    it "returns snapshot_fact" do
      expect(close_result[:snapshot_fact]).not_to be_nil
    end

    it "returns derivation receipt_fact" do
      expect(close_result[:receipt_fact]).not_to be_nil
    end

    it "writes a boundary record to :ledger_boundaries" do
      close_result
      boundary_fact = store.history(store: :ledger_boundaries).last
      expect(boundary_fact).not_to be_nil
      expect(boundary_fact.value[:boundary_key]).to include("technician_day")
      expect(boundary_fact.value[:status]).to eq("closed")
      expect(boundary_fact.value[:result_hash]).to eq(close_result[:boundary].result_hash)
    end

    it "writes closure receipt to :ledger_boundary_receipts" do
      close_result
      receipt = store.history(store: :ledger_boundary_receipts).last
      expect(receipt).not_to be_nil
      expect(receipt.value[:boundary_key]).to eq(close_result[:boundary].boundary_key)
      expect(receipt.value[:output_fact_id]).to eq(close_result[:boundary].output_fact_id)
      expect(receipt.value[:result_hash]).to eq(close_result[:boundary].result_hash)
    end

    it "source_fact_ids includes the template fact ID" do
      tmpl = ledger.write_template(technician_id: "tech-s2b", weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: "tech-s2b", date: BOUNDARY_PROOF_DATE)
      r = ledger.close_boundary(company_id: company, technician_id: "tech-s2b", date: BOUNDARY_PROOF_DATE)
      expect(r[:boundary].source_fact_ids).to include(tmpl.id)
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: boundary replay returns closed output without full scan" do
    let(:tid) { "tech-s3" }
    let!(:boundary_key) do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r = ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r[:boundary].boundary_key
    end

    it "returns status: :ok with fidelity: :boundary" do
      result = ledger.replay(boundary_key)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:boundary)
    end

    it "output matches the closed snapshot (8h for Monday template)" do
      result = ledger.replay(boundary_key)
      expect(result[:output]).not_to be_nil
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end

    it "includes boundary_id, result_hash, and detail_status: :full" do
      result = ledger.replay(boundary_key)
      expect(result[:boundary_id]).to eq(boundary_key)
      expect(result[:result_hash]).not_to be_nil
      expect(result[:detail_status]).to eq(:full)
    end

    it "returns :open for an open boundary" do
      ledger.open_boundary(company_id: company, technician_id: "tech-s3-open", date: BOUNDARY_PROOF_DATE)
      open_key = IntelligentLedger::LedgerBoundary.key_for(
        company_id: company, technician_id: "tech-s3-open", date: BOUNDARY_PROOF_DATE.to_s
      )
      expect(ledger.replay(open_key)[:status]).to eq(:open)
    end

    it "returns :not_found for an unknown boundary" do
      expect(ledger.replay("technician_day/company=x/technician=y/date=z/version=1.0")[:status])
        .to eq(:not_found)
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: full replay before and after compaction" do
    let(:tid) { "tech-s4" }

    before do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
    end

    it "returns status: :ok with fidelity: :full before compaction" do
      result = ledger.full_replay(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:full)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end

    context "after compaction" do
      let(:boundary_key) do
        IntelligentLedger::LedgerBoundary.key_for(
          company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE.to_s
        )
      end

      before do
        ledger.settle_boundary(boundary_key)
        ledger.compact_boundary(boundary_key)
      end

      it "returns status: :detail_unavailable" do
        result = ledger.full_replay(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
        expect(result[:status]).to eq(:detail_unavailable)
      end

      it "reports detail_status: :purged" do
        result = ledger.full_replay(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
        expect(result[:detail_status]).to eq(:purged)
      end

      it "includes boundary_id and boundary_receipt_id" do
        result = ledger.full_replay(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
        expect(result[:boundary_id]).to include("technician_day")
        expect(result[:boundary_receipt_id]).not_to be_nil
      end
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: compaction writes cleanup receipt and marks detail_status :purged" do
    let(:tid) { "tech-s5" }
    let!(:boundary_key) do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r = ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r[:boundary].boundary_key
    end

    # Settlement is required before compaction.
    before { ledger.settle_boundary(boundary_key) }

    it "compact_boundary writes to :ledger_cleanup_receipts" do
      ledger.compact_boundary(boundary_key)
      stored = store.history(store: :ledger_cleanup_receipts, key: boundary_key).last
      expect(stored).not_to be_nil
      expect(stored.value[:detail_status_after]).to eq("purged")
    end

    it "compaction receipt preserves result_hash" do
      boundary = ledger.find_boundary(boundary_key)
      original = boundary.result_hash
      ledger.compact_boundary(boundary_key)
      stored = store.history(store: :ledger_cleanup_receipts, key: boundary_key).last
      expect(stored.value[:result_hash]).to eq(original)
    end

    it "compaction receipt preserves output_fact_id" do
      boundary = ledger.find_boundary(boundary_key)
      original_output_id = boundary.output_fact_id
      ledger.compact_boundary(boundary_key)
      stored = store.history(store: :ledger_cleanup_receipts, key: boundary_key).last
      expect(stored.value[:output_fact_id]).to eq(original_output_id)
    end

    it "boundary transitions to :compacted with detail_status :purged" do
      ledger.compact_boundary(boundary_key)
      boundary = ledger.find_boundary(boundary_key)
      expect(boundary.status).to eq(:compacted)
      expect(boundary.detail_status).to eq(:purged)
      expect(boundary.compacted?).to be true
    end

    it "result_hash is preserved after compaction" do
      boundary  = ledger.find_boundary(boundary_key)
      pre_hash  = boundary.result_hash
      ledger.compact_boundary(boundary_key)
      expect(boundary.result_hash).to eq(pre_hash)
    end

    it "boundary replay still returns the same output after compaction" do
      expected_seconds = ledger.replay(boundary_key)[:output][:available_seconds]
      ledger.compact_boundary(boundary_key)
      result = ledger.replay(boundary_key)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:boundary)
      expect(result[:output][:available_seconds]).to eq(expected_seconds)
      expect(result[:detail_status]).to eq(:purged)
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: cleanup plan blocked by open boundary, ready after closure" do
    let(:tid)    { "tech-s6" }
    let(:cutoff) { Time.utc(2026, 5, 5, 0, 0, 0) }

    before { ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE) }

    it "plan is :blocked while the required boundary is open" do
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:status]).to eq(:blocked)
      expect(plan[:blocking_boundaries]).not_to be_empty
    end

    it "blocked plan lists the blocking boundary key" do
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      expected_key = IntelligentLedger::LedgerBoundary.key_for(
        company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE.to_s
      )
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:blocking_boundaries]).to include(expected_key)
    end

    it "plan becomes :ready after the boundary is settled" do
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      bk = IntelligentLedger::LedgerBoundary.key_for(
        company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE.to_s
      )
      ledger.settle_boundary(bk)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:status]).to eq(:ready)
      expect(plan[:blocking_boundaries]).to be_empty
    end

    it "ready plan includes boundary receipt IDs for retention" do
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      bk = IntelligentLedger::LedgerBoundary.key_for(
        company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE.to_s
      )
      ledger.settle_boundary(bk)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:receipts_to_keep]).not_to be_empty
    end

    it "ready plan lists required boundary policies" do
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      bk = IntelligentLedger::LedgerBoundary.key_for(
        company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE.to_s
      )
      ledger.settle_boundary(bk)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:required_boundary_policies]).to include(:technician_day)
    end

    it "boundary beyond the cutoff does not block the plan" do
      future_date = Date.new(2026, 5, 6)
      ledger.open_boundary(company_id: company, technician_id: tid, date: future_date)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff, fidelity: :boundary)
      expect(plan[:status]).to eq(:ready)
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: late fact creates correction evidence; original result_hash unchanged" do
    let(:tid) { "tech-s7" }
    let!(:boundary_key) do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r = ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      r[:boundary].boundary_key
    end

    let(:original_hash) { ledger.find_boundary(boundary_key).result_hash }

    it "write_late_fact returns a late-fact receipt" do
      receipt = ledger.write_late_fact(
        boundary_key: boundary_key,
        fact_value:   { "order_id" => "order-late-1", "type" => "reserved" },
        fact_type:    :order_event
      )
      expect(receipt).not_to be_nil
    end

    it "late-fact receipt is persisted to :late_fact_receipts store" do
      ledger.write_late_fact(
        boundary_key: boundary_key,
        fact_value:   { "order_id" => "order-late-2", "type" => "reserved" },
        fact_type:    :order_event
      )
      stored = store.history(store: :late_fact_receipts).last
      expect(stored).not_to be_nil
      expect(stored.value[:boundary_key]).to eq(boundary_key)
      expect(stored.value[:disposition]).to eq("correction_boundary")
    end

    it "receipt preserves the original_result_hash at the time of closure" do
      original = original_hash
      ledger.write_late_fact(
        boundary_key: boundary_key,
        fact_value:   { "order_id" => "order-late-3" },
        fact_type:    :order_event
      )
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:original_result_hash]).to eq(original)
    end

    it "does not mutate the original boundary result_hash" do
      original = original_hash
      ledger.write_late_fact(
        boundary_key: boundary_key,
        fact_value:   { "order_id" => "order-late-4", "type" => "reserved" },
        fact_type:    :order_event
      )
      expect(ledger.find_boundary(boundary_key).result_hash).to eq(original)
    end

    it "does not change the boundary status after a late fact" do
      ledger.write_late_fact(
        boundary_key: boundary_key,
        fact_value:   { "order_id" => "order-late-5" },
        fact_type:    :order_event
      )
      expect(ledger.find_boundary(boundary_key).status).to eq(:closed)
    end

    it "also works when boundary is :compacted" do
      bk = boundary_key
      ledger.settle_boundary(bk)
      ledger.compact_boundary(bk)
      receipt = ledger.write_late_fact(
        boundary_key: bk,
        fact_value:   { "order_id" => "order-late-compact" },
        fact_type:    :order_event
      )
      expect(receipt).not_to be_nil
      expect(ledger.find_boundary(bk).result_hash).to eq(original_hash)
    end
  end

  # ── Scenario 8 ───────────────────────────────────────────────────────────────

  describe "Scenario 8: AvailabilityBoundaryLedger delegates fact writes to underlying ledger" do
    let(:tid) { "tech-s8" }

    it "write_template is visible to the underlying AvailabilityLedger" do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)

      underlying = IntelligentLedger::AvailabilityLedger.new(store: store)
      result = underlying.compute_snapshot(
        technician_id: tid,
        horizon_start: BOUNDARY_PROOF_DATE,
        horizon_days:  1
      )
      expect(result[:snapshot_fact].value[:available_seconds]).to eq(8 * 3600)
    end

    it "close_boundary does not break subsequent read_snapshot on underlying ledger" do
      ledger.write_template(technician_id: tid, weekly_schedule: BOUNDARY_WEEKDAY_SCHEDULE)
      ledger.open_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)
      ledger.close_boundary(company_id: company, technician_id: tid, date: BOUNDARY_PROOF_DATE)

      underlying = IntelligentLedger::AvailabilityLedger.new(store: store)
      snap = underlying.read_snapshot(
        technician_id: tid,
        horizon_start: BOUNDARY_PROOF_DATE,
        horizon_days:  1
      )
      expect(snap).not_to be_nil
      expect(snap.value[:available_seconds]).to eq(8 * 3600)
    end
  end
end
