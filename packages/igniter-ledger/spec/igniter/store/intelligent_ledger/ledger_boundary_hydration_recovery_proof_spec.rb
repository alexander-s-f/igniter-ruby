# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

# Intelligent Ledger — LedgerBoundary Hydration Recovery Proof
#
# Research question:
#   Can boundary truth be restored from persisted receipts strongly enough that
#   boundary replay and cleanup semantics still work after restart?
#
# All tests follow the same pattern:
#   1. ledger1 performs operations on a shared IgniterStore
#   2. ledger2 = fresh AvailabilityBoundaryLedger on the SAME store (simulates restart)
#   3. ledger2.hydrate_boundaries — rebuilds in-memory registry from persisted facts
#   4. Assertions on ledger2
#
#   Scenario 1:  no persisted boundaries → hydrated_count: 0
#   Scenario 2:  closed boundary hydrates; replay works and returns original output
#   Scenario 3:  settled boundary hydrates with settlement_status: :settled
#   Scenario 4:  compacted boundary hydrates with status: :compacted, detail_status: :purged
#   Scenario 5:  full_replay after hydration: :detail_unavailable for compacted boundaries
#   Scenario 6:  cleanup_plan after hydration: blocked for unsettled, ready for settled
#   Scenario 7:  compact_boundary works after hydration for settled-but-not-compacted
#   Scenario 8:  write_late_fact works after hydration; records restored status fields
#   Scenario 9:  idempotency — running hydrate_boundaries twice does not duplicate
#   Scenario 10: missing closure receipt → skipped with warning; hydration report correct
IntelligentLedger = Igniter::Store::IntelligentLedger unless defined?(IntelligentLedger)

RSpec.describe "Intelligent Ledger: LedgerBoundary hydration recovery proof" do
  HYDRATION_DATE     = Date.new(2026, 5, 4)
  HYDRATION_SCHEDULE = {
    "1" => [["09:00", "17:00"]],
    "2" => [["09:00", "17:00"]],
    "3" => [["09:00", "17:00"]],
    "4" => [["09:00", "17:00"]],
    "5" => [["09:00", "17:00"]]
  }.freeze

  # Shared IgniterStore — persists across ledger instances within a test.
  subject(:store) { Igniter::Store::IgniterStore.new }

  let(:company) { "company-hydrate" }

  # Helper: first-pass ledger (writes facts to store)
  def ledger1 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)

  # Helper: second-pass ledger (simulates restart — empty @boundaries, same store)
  def ledger2 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)

  def boundary_key_for(tid)
    IntelligentLedger::LedgerBoundary.key_for(
      company_id: company, technician_id: tid, date: HYDRATION_DATE.to_s
    )
  end

  def setup_closed(l1, tid)
    l1.write_template(technician_id: tid, weekly_schedule: HYDRATION_SCHEDULE)
    l1.open_boundary(company_id: company, technician_id: tid, date: HYDRATION_DATE)
    l1.close_boundary(company_id: company, technician_id: tid, date: HYDRATION_DATE)
  end

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: no persisted boundaries → hydrated_count: 0" do
    it "returns status :ok with hydrated_count 0 when store is empty" do
      report = ledger2.hydrate_boundaries
      expect(report[:status]).to eq(:ok)
      expect(report[:hydrated_count]).to eq(0)
      expect(report[:skipped_count]).to eq(0)
      expect(report[:warnings]).to be_empty
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: closed boundary hydrates; replay returns original output" do
    let(:tid) { "tech-hydrate-s2" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      @s2_original_hash = l1.find_boundary(bk).result_hash
    end

    subject(:l2) do
      l = ledger2
      l.hydrate_boundaries
      l
    end

    it "hydration report shows 1 hydrated" do
      l = ledger2
      report = l.hydrate_boundaries
      expect(report[:hydrated_count]).to eq(1)
      expect(report[:skipped_count]).to eq(0)
    end

    it "find_boundary returns a boundary after hydration" do
      expect(l2.find_boundary(bk)).not_to be_nil
    end

    it "hydrated boundary has status :closed" do
      expect(l2.find_boundary(bk).status).to eq(:closed)
    end

    it "replay returns :ok with fidelity :boundary" do
      result = l2.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:fidelity]).to eq(:boundary)
    end

    it "replay output matches original snapshot (8h for Monday template)" do
      result = l2.replay(bk)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end

    it "result_hash matches the original boundary" do
      expect(l2.find_boundary(bk).result_hash).to eq(@s2_original_hash)
    end

    it "source_fact_ids is restored" do
      expect(l2.find_boundary(bk).source_fact_ids).not_to be_empty
    end

    it "output_fact_id is restored" do
      expect(l2.find_boundary(bk).output_fact_id).not_to be_nil
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: settled boundary hydrates with settlement_status :settled" do
    let(:tid) { "tech-hydrate-s3" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
    end

    subject(:l2) do
      l = ledger2
      l.hydrate_boundaries
      l
    end

    it "hydrated boundary has settlement_status :settled" do
      expect(l2.find_boundary(bk).settlement_status).to eq(:settled)
      expect(l2.find_boundary(bk).settled?).to be true
    end

    it "settlement_receipt_id is restored" do
      expect(l2.find_boundary(bk).settlement_receipt_id).not_to be_nil
    end

    it "status remains :closed after settlement hydration" do
      expect(l2.find_boundary(bk).status).to eq(:closed)
    end

    it "replay still works after settlement hydration" do
      result = l2.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: compacted boundary hydrates with status :compacted, detail_status :purged" do
    let(:tid) { "tech-hydrate-s4" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
      @s4_original_hash = l1.find_boundary(bk).result_hash
      l1.compact_boundary(bk)
    end

    subject(:l2) do
      l = ledger2
      l.hydrate_boundaries
      l
    end

    it "hydrated boundary has status :compacted" do
      expect(l2.find_boundary(bk).status).to eq(:compacted)
      expect(l2.find_boundary(bk).compacted?).to be true
    end

    it "hydrated boundary has detail_status :purged" do
      expect(l2.find_boundary(bk).detail_status).to eq(:purged)
    end

    it "settlement_status is :settled after compaction hydration" do
      expect(l2.find_boundary(bk).settlement_status).to eq(:settled)
      expect(l2.find_boundary(bk).settled?).to be true
    end

    it "result_hash is preserved after compaction hydration" do
      expect(l2.find_boundary(bk).result_hash).to eq(@s4_original_hash)
    end

    it "compaction_receipt_id is restored" do
      expect(l2.find_boundary(bk).compaction_receipt_id).not_to be_nil
    end

    it "replay still returns correct output after compaction hydration" do
      result = l2.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
      expect(result[:detail_status]).to eq(:purged)
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: full_replay after hydration: :detail_unavailable for compacted" do
    let(:tid) { "tech-hydrate-s5" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
      l1.compact_boundary(bk)
    end

    it "full_replay returns :detail_unavailable after hydration of compacted boundary" do
      l = ledger2
      l.hydrate_boundaries
      result = l.full_replay(company_id: company, technician_id: tid, date: HYDRATION_DATE)
      expect(result[:status]).to eq(:detail_unavailable)
      expect(result[:detail_status]).to eq(:purged)
    end

    it "full_replay includes boundary_receipt_id" do
      l = ledger2
      l.hydrate_boundaries
      result = l.full_replay(company_id: company, technician_id: tid, date: HYDRATION_DATE)
      expect(result[:boundary_receipt_id]).not_to be_nil
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: cleanup_plan after hydration" do
    let(:cutoff) { Time.utc(2026, 5, 5, 0, 0, 0) }

    it "cleanup_plan is blocked for a closed-but-unsettled hydrated boundary" do
      tid = "tech-hydrate-s6a"
      l1 = ledger1
      setup_closed(l1, tid)

      l = ledger2
      l.hydrate_boundaries
      plan = l.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:status]).to eq(:blocked)
      expect(plan[:blocking_reasons][boundary_key_for(tid)]).to eq(:settlement_required)
    end

    it "cleanup_plan is ready for a settled hydrated boundary" do
      tid = "tech-hydrate-s6b"
      bk  = boundary_key_for(tid)
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)

      l = ledger2
      l.hydrate_boundaries
      plan = l.cleanup_plan(store: :order_events, before: cutoff)
      expect(plan[:status]).to eq(:ready)
      expect(plan[:blocking_boundaries]).to be_empty
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: compact_boundary works after hydration for settled-but-not-compacted" do
    let(:tid) { "tech-hydrate-s7" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
      # NOTE: not compacted in ledger1
    end

    it "compact_boundary succeeds on hydrated settled boundary" do
      l = ledger2
      l.hydrate_boundaries
      expect { l.compact_boundary(bk) }.not_to raise_error
    end

    it "boundary transitions to :compacted after compact on hydrated settled boundary" do
      l = ledger2
      l.hydrate_boundaries
      l.compact_boundary(bk)
      expect(l.find_boundary(bk).status).to eq(:compacted)
      expect(l.find_boundary(bk).detail_status).to eq(:purged)
    end

    it "replay still works after compact on hydrated settled boundary" do
      l = ledger2
      l.hydrate_boundaries
      l.compact_boundary(bk)
      result = l.replay(bk)
      expect(result[:status]).to eq(:ok)
      expect(result[:output][:available_seconds]).to eq(8 * 3600)
    end
  end

  # ── Scenario 8 ───────────────────────────────────────────────────────────────

  describe "Scenario 8: write_late_fact works after hydration; records restored status fields" do
    let(:tid) { "tech-hydrate-s8" }
    let(:bk)  { boundary_key_for(tid) }

    it "write_late_fact succeeds on a hydrated closed boundary" do
      l1 = ledger1
      setup_closed(l1, tid)

      l = ledger2
      l.hydrate_boundaries
      expect do
        l.write_late_fact(boundary_key: bk,
                          fact_value: { "order_id" => "order-late-hydrate" },
                          fact_type:  :order_event)
      end.not_to raise_error
    end

    it "late-fact receipt records boundary_status_at_arrival: 'closed'" do
      l1 = ledger1
      setup_closed(l1, tid)

      l = ledger2
      l.hydrate_boundaries
      l.write_late_fact(boundary_key: bk,
                        fact_value: { "order_id" => "order-late-h2" },
                        fact_type:  :order_event)
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:boundary_status_at_arrival]).to eq("closed")
    end

    it "late-fact after hydrated settled boundary records settlement_status_at_arrival: 'settled'" do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)

      l = ledger2
      l.hydrate_boundaries
      l.write_late_fact(boundary_key: bk,
                        fact_value: { "order_id" => "order-late-h3" },
                        fact_type:  :order_event)
      stored = store.history(store: :late_fact_receipts).last
      expect(stored.value[:settlement_status_at_arrival]).to eq("settled")
    end

    it "does not mutate original result_hash after late fact on hydrated boundary" do
      l1 = ledger1
      setup_closed(l1, tid)
      original = l1.find_boundary(bk).result_hash

      l = ledger2
      l.hydrate_boundaries
      l.write_late_fact(boundary_key: bk,
                        fact_value: { "order_id" => "order-late-h4" },
                        fact_type:  :order_event)
      expect(l.find_boundary(bk).result_hash).to eq(original)
    end
  end

  # ── Scenario 9 ───────────────────────────────────────────────────────────────

  describe "Scenario 9: idempotency — running hydrate_boundaries twice does not duplicate" do
    let(:tid) { "tech-hydrate-s9" }
    let(:bk)  { boundary_key_for(tid) }

    before { setup_closed(ledger1, tid) }

    it "second hydration reports 0 hydrated (all already in registry)" do
      l = ledger2
      l.hydrate_boundaries
      report2 = l.hydrate_boundaries
      expect(report2[:hydrated_count]).to eq(0)
    end

    it "find_boundary returns the same object both times" do
      l = ledger2
      l.hydrate_boundaries
      first  = l.find_boundary(bk)
      l.hydrate_boundaries
      second = l.find_boundary(bk)
      expect(first).to equal(second)
    end

    it "does not write any new store facts on second hydration" do
      l = ledger2
      l.hydrate_boundaries
      count_before = store.history(store: :ledger_boundaries).size
      l.hydrate_boundaries
      expect(store.history(store: :ledger_boundaries).size).to eq(count_before)
    end
  end

  # ── Scenario 10 ──────────────────────────────────────────────────────────────

  describe "Scenario 10: missing closure receipt → skipped with warning; counts correct" do
    it "skips boundary that has a boundary record but no closure receipt" do
      # Write a boundary record directly to simulate an incomplete persist
      store.write(
        store:    :ledger_boundaries,
        key:      "technician_day/company=x/technician=orphan/date=2026-05-04/version=1.0",
        value:    {
          "boundary_key"    => "technician_day/company=x/technician=orphan/date=2026-05-04/version=1.0",
          "subject"         => { "company_id" => "x", "technician_id" => "orphan", "date" => "2026-05-04" },
          "status"          => "closed",
          "output_fact_id"  => "fake-output-id",
          "receipt_fact_id" => "fake-receipt-id",
          "result_hash"     => "abc123",
          "source_fact_ids" => [],
          "detail_status"   => "full",
          "closed_at"       => Time.now.iso8601(3),
          "rule_version"    => "1.0"
        },
        producer: { "system" => "test" }
      )

      report = ledger2.hydrate_boundaries
      expect(report[:skipped_count]).to eq(1)
      expect(report[:warnings]).not_to be_empty
      expect(report[:warnings].first).to include("closure receipt missing")
    end

    it "reports hydrated_count for valid boundaries alongside skipped orphans" do
      tid = "tech-hydrate-s10b"
      setup_closed(ledger1, tid)

      # Also inject an orphan
      store.write(
        store:    :ledger_boundaries,
        key:      "technician_day/company=x/technician=orphan2/date=2026-05-04/version=1.0",
        value:    {
          "boundary_key"    => "technician_day/company=x/technician=orphan2/date=2026-05-04/version=1.0",
          "subject"         => { "company_id" => "x", "technician_id" => "orphan2", "date" => "2026-05-04" },
          "status"          => "closed",
          "output_fact_id"  => "fake-2",
          "receipt_fact_id" => "fake-r-2",
          "result_hash"     => "def456",
          "source_fact_ids" => [],
          "detail_status"   => "full",
          "closed_at"       => Time.now.iso8601(3),
          "rule_version"    => "1.0"
        },
        producer: { "system" => "test" }
      )

      report = ledger2.hydrate_boundaries
      expect(report[:hydrated_count]).to eq(1)
      expect(report[:skipped_count]).to eq(1)
      expect(report[:status]).to eq(:ok)
    end
  end
end
