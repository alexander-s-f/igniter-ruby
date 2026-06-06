# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

# Intelligent Ledger — LedgerBoundary Reference Redirects Proof
#
# Research question:
#   Can references to raw internal facts redirect to boundary proof after compaction,
#   without raw-fidelity callers getting a silent downgrade to boundary evidence?
#
# Test pattern:
#   1. ledger1 performs open → close → settle → compact on a shared store.
#   2. Redirects are written to :ledger_fact_redirects at compaction time.
#   3. resolve_ref is called with :raw, :boundary, :summary fidelities.
#   4. Restart scenarios use a fresh ledger2 instance (no hydration needed for
#      redirect resolution — redirects are read directly from the persisted store).
#
#   Scenario 1:  compact_boundary writes one redirect per source_fact_id
#   Scenario 2:  redirect fields are complete (all required fields present)
#   Scenario 3:  boundary with zero source_fact_ids compacts with zero redirects
#   Scenario 4:  resolve_ref(:boundary) → :redirected (intentional follow)
#   Scenario 5:  resolve_ref(:raw) without assume_compacted → :ok (raw fact accessible)
#   Scenario 6:  resolve_ref(:raw, assume_compacted: true) → :detail_unavailable (no silent downgrade)
#   Scenario 7:  resolve_ref(:summary) → :redirected with settlement_receipt_id in evidence
#   Scenario 8:  redirect resolution works on fresh ledger without hydration (restart proof)
#   Scenario 9:  unknown fact_id → :not_found for all fidelities
#   Scenario 10: unsupported fidelity → ArgumentError
#   Scenario 11: multiple redirects for same fact_id → latest by transaction_time used

IntelligentLedger = Igniter::Store::IntelligentLedger unless defined?(IntelligentLedger)

RSpec.describe "Intelligent Ledger: LedgerBoundary reference redirects proof" do
  REDIRECT_DATE     = Date.new(2026, 5, 4)
  REDIRECT_SCHEDULE = {
    "1" => [["09:00", "17:00"]],
    "2" => [["09:00", "17:00"]],
    "3" => [["09:00", "17:00"]],
    "4" => [["09:00", "17:00"]],
    "5" => [["09:00", "17:00"]]
  }.freeze

  subject(:store) { Igniter::Store::IgniterStore.new }

  let(:company) { "company-redirect" }

  def ledger1 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)
  def ledger2 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)

  def boundary_key_for(tid)
    IntelligentLedger::LedgerBoundary.key_for(
      company_id: company, technician_id: tid, date: REDIRECT_DATE.to_s
    )
  end

  # Closes boundary and returns the ledger with an open+closed boundary.
  def setup_closed(l1, tid)
    l1.write_template(technician_id: tid, weekly_schedule: REDIRECT_SCHEDULE)
    l1.open_boundary(company_id: company, technician_id: tid, date: REDIRECT_DATE)
    l1.close_boundary(company_id: company, technician_id: tid, date: REDIRECT_DATE)
  end

  # Runs the full lifecycle on ledger l1 and returns it.
  def setup_compacted(l1, tid)
    setup_closed(l1, tid)
    bk = boundary_key_for(tid)
    l1.settle_boundary(bk)
    l1.compact_boundary(bk)
    l1
  end

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: compact_boundary writes one redirect per source_fact_id" do
    let(:tid) { "tech-redirect-s1" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
      @source_ids = l1.find_boundary(bk).source_fact_ids.dup
      l1.compact_boundary(bk)
    end

    it "writes exactly one redirect per source_fact_id" do
      all_redirects = store.history(store: :ledger_fact_redirects)
      expect(all_redirects.size).to eq(@source_ids.size)
    end

    it "redirect key is the original fact_id" do
      @source_ids.each do |src_id|
        redirect_facts = store.history(store: :ledger_fact_redirects, key: src_id)
        expect(redirect_facts).not_to be_empty
      end
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: redirect fact preserves all required fields" do
    let(:tid) { "tech-redirect-s2" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      l1.settle_boundary(bk)
      @boundary    = l1.find_boundary(bk)
      @src_id      = @boundary.source_fact_ids.first
      l1.compact_boundary(bk)
      @redirect    = store.history(store: :ledger_fact_redirects, key: @src_id).last.value
    end

    it "preserves original_fact_id" do
      expect(@redirect[:original_fact_id]).to eq(@src_id)
    end

    it "preserves boundary_key" do
      expect(@redirect[:boundary_key]).to eq(bk)
    end

    it "preserves boundary_policy" do
      expect(@redirect[:boundary_policy]).to eq(IntelligentLedger::LedgerBoundary::POLICY_NAME)
    end

    it "preserves boundary_output_fact_id" do
      expect(@redirect[:boundary_output_fact_id]).to eq(@boundary.output_fact_id)
    end

    it "preserves boundary_receipt_id" do
      expect(@redirect[:boundary_receipt_id]).to eq(@boundary.receipt_fact_id)
    end

    it "preserves settlement_receipt_id" do
      expect(@redirect[:settlement_receipt_id]).to eq(@boundary.settlement_receipt_id)
    end

    it "preserves compaction_receipt_id" do
      expect(@redirect[:compaction_receipt_id]).not_to be_nil
      expect(@redirect[:compaction_receipt_id]).to eq(@boundary.compaction_receipt_id)
    end

    it "has detail_status: purged" do
      expect(@redirect[:detail_status]).to eq("purged")
    end

    it "has reference_role: included_in_boundary" do
      expect(@redirect[:reference_role]).to eq("included_in_boundary")
    end

    it "has compacted_at timestamp" do
      expect(@redirect[:compacted_at]).not_to be_nil
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: boundary with zero source_fact_ids compacts with zero redirects" do
    let(:tid) { "tech-redirect-s3-empty" }
    let(:bk)  { boundary_key_for(tid) }

    it "compact_boundary succeeds and writes zero redirects" do
      l1 = ledger1
      # Manually create a boundary with empty source_fact_ids.
      # open → close via a technician with no template (snapshot has no source facts).
      l1.open_boundary(company_id: company, technician_id: tid, date: REDIRECT_DATE)
      boundary = l1.find_boundary(bk)

      # Synthesise a minimal output_fact and receipt_fact via a stub store write,
      # then close the boundary with an empty source list.
      output_fact  = store.write(store: :availability_snapshots,
                                 key:   "#{tid}/stub",
                                 value: { "available_seconds" => 0 })
      receipt_fact = store.write(store: :derivation_receipts,
                                 key:   output_fact.id,
                                 value: { "stub" => true })
      boundary.close!(output_fact: output_fact, receipt_fact: receipt_fact, source_fact_ids: [])

      store.write(
        store: :ledger_boundaries, key: bk,
        value: { "boundary_key" => bk, "output_fact_id" => output_fact.id,
                 "receipt_fact_id" => receipt_fact.id, "source_fact_ids" => [],
                 "result_hash" => boundary.result_hash, "detail_status" => "full",
                 "subject" => boundary.subject.transform_keys(&:to_s),
                 "closed_at" => Time.now.iso8601(3), "rule_version" => "1.0" }
      )
      store.write(store: :ledger_boundary_receipts, key: bk,
                  value: { "boundary_key" => bk })

      l1.settle_boundary(bk)
      l1.compact_boundary(bk)

      redirects = store.history(store: :ledger_fact_redirects)
      expect(redirects).to be_empty
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: resolve_ref(:boundary) → :redirected" do
    let(:tid) { "tech-redirect-s4" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @src_id = l1.find_boundary(bk).source_fact_ids.first
      @ledger = l1
    end

    it "returns status :redirected" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:status]).to eq(:redirected)
    end

    it "returns kind :boundary_ref" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:kind]).to eq(:boundary_ref)
    end

    it "returns the correct boundary_key" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:boundary_key]).to eq(bk)
    end

    it "detail_status is :purged" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:detail_status]).to eq(:purged)
    end

    it "evidence contains boundary_output_fact_id" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:evidence][:boundary_output_fact_id]).not_to be_nil
    end

    it "evidence contains boundary_receipt_id" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:evidence][:boundary_receipt_id]).not_to be_nil
    end

    it "evidence contains settlement_receipt_id" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:evidence][:settlement_receipt_id]).not_to be_nil
    end

    it "evidence contains compaction_receipt_id" do
      result = @ledger.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:evidence][:compaction_receipt_id]).not_to be_nil
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: resolve_ref(:raw) without assume_compacted → :ok (no silent downgrade)" do
    let(:tid) { "tech-redirect-s5" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @src_id = l1.find_boundary(bk).source_fact_ids.first
      @ledger = l1
    end

    it "returns status :ok (raw fact still physically accessible)" do
      result = @ledger.resolve_ref(@src_id, fidelity: :raw)
      expect(result[:status]).to eq(:ok)
    end

    it "returns kind :raw_fact" do
      result = @ledger.resolve_ref(@src_id, fidelity: :raw)
      expect(result[:kind]).to eq(:raw_fact)
    end

    it "returns the raw fact object (not boundary evidence)" do
      result = @ledger.resolve_ref(@src_id, fidelity: :raw)
      expect(result[:fact]).not_to be_nil
      expect(result[:fact].id).to eq(@src_id)
    end

    it "does NOT return status :redirected (raw is not silently downgraded)" do
      result = @ledger.resolve_ref(@src_id, fidelity: :raw)
      expect(result[:status]).not_to eq(:redirected)
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: resolve_ref(:raw, assume_compacted: true) → :detail_unavailable" do
    let(:tid) { "tech-redirect-s6" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @src_id = l1.find_boundary(bk).source_fact_ids.first
      @ledger = l1
    end

    subject(:result) { @ledger.resolve_ref(@src_id, fidelity: :raw, assume_compacted: true) }

    it "returns status :detail_unavailable" do
      expect(result[:status]).to eq(:detail_unavailable)
    end

    it "returns required_fidelity: :raw" do
      expect(result[:required_fidelity]).to eq(:raw)
    end

    it "returns available_fidelity: :boundary" do
      expect(result[:available_fidelity]).to eq(:boundary)
    end

    it "returns the original_fact_id" do
      expect(result[:original_fact_id]).to eq(@src_id)
    end

    it "returns the boundary_key" do
      expect(result[:boundary_key]).to eq(bk)
    end

    it "includes evidence with compaction_receipt_id" do
      expect(result[:evidence][:compaction_receipt_id]).not_to be_nil
    end

    it "does NOT return :ok (raw not silently found)" do
      expect(result[:status]).not_to eq(:ok)
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: resolve_ref(:summary) → :redirected with settlement evidence" do
    let(:tid) { "tech-redirect-s7" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @src_id        = l1.find_boundary(bk).source_fact_ids.first
      @settlement_id = l1.find_boundary(bk).settlement_receipt_id
      @ledger        = l1
    end

    subject(:result) { @ledger.resolve_ref(@src_id, fidelity: :summary) }

    it "returns status :redirected" do
      expect(result[:status]).to eq(:redirected)
    end

    it "returns kind :summary_ref" do
      expect(result[:kind]).to eq(:summary_ref)
    end

    it "evidence includes settlement_receipt_id" do
      expect(result[:evidence][:settlement_receipt_id]).to eq(@settlement_id)
    end

    it "evidence includes compaction_receipt_id" do
      expect(result[:evidence][:compaction_receipt_id]).not_to be_nil
    end
  end

  # ── Scenario 8 ───────────────────────────────────────────────────────────────

  describe "Scenario 8: resolution works on a fresh ledger without hydration (restart proof)" do
    let(:tid) { "tech-redirect-s8" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @src_id = l1.find_boundary(bk).source_fact_ids.first
    end

    it "resolve_ref(:boundary) returns :redirected on fresh ledger (no hydrate)" do
      l2     = ledger2
      result = l2.resolve_ref(@src_id, fidelity: :boundary)
      expect(result[:status]).to eq(:redirected)
      expect(result[:boundary_key]).to eq(bk)
    end

    it "resolve_ref(:raw, assume_compacted: true) returns :detail_unavailable on fresh ledger" do
      l2     = ledger2
      result = l2.resolve_ref(@src_id, fidelity: :raw, assume_compacted: true)
      expect(result[:status]).to eq(:detail_unavailable)
    end

    it "resolve_ref(:summary) returns :redirected on fresh hydrated ledger" do
      l2 = ledger2
      l2.hydrate_boundaries
      result = l2.resolve_ref(@src_id, fidelity: :summary)
      expect(result[:status]).to eq(:redirected)
      expect(result[:kind]).to eq(:summary_ref)
    end
  end

  # ── Scenario 9 ───────────────────────────────────────────────────────────────

  describe "Scenario 9: unknown fact_id → :not_found for all fidelities" do
    let(:unknown_id) { "00000000-0000-0000-0000-000000000000" }

    before { setup_compacted(ledger1, "tech-redirect-s9") }

    it "returns :not_found for :boundary fidelity" do
      result = ledger1.resolve_ref(unknown_id, fidelity: :boundary)
      expect(result[:status]).to eq(:not_found)
      expect(result[:original_fact_id]).to eq(unknown_id)
    end

    it "returns :not_found for :raw fidelity" do
      result = ledger1.resolve_ref(unknown_id, fidelity: :raw)
      expect(result[:status]).to eq(:not_found)
    end

    it "returns :not_found for :summary fidelity" do
      result = ledger1.resolve_ref(unknown_id, fidelity: :summary)
      expect(result[:status]).to eq(:not_found)
    end
  end

  # ── Scenario 10 ──────────────────────────────────────────────────────────────

  describe "Scenario 10: unsupported fidelity → ArgumentError" do
    before do
      l1 = ledger1
      setup_compacted(l1, "tech-redirect-s10")
      bk      = boundary_key_for("tech-redirect-s10")
      @src_id = l1.find_boundary(bk).source_fact_ids.first
      @ledger = l1
    end

    it "raises ArgumentError for unsupported fidelity" do
      expect { @ledger.resolve_ref(@src_id, fidelity: :full_detail) }
        .to raise_error(ArgumentError, /unsupported fidelity/)
    end
  end

  # ── Scenario 11 ──────────────────────────────────────────────────────────────

  describe "Scenario 11: multiple redirects for same fact_id → latest used" do
    let(:tid)      { "tech-redirect-s11" }
    let(:bk)       { boundary_key_for(tid) }
    let(:fact_key) { "some-fact-id-s11" }

    it "resolve_ref picks the redirect with the latest transaction_time" do
      l1 = ledger1

      # Write two redirects manually — earlier with boundary_key "old", later with "new".
      store.write(
        store: :ledger_fact_redirects, key: fact_key,
        value: {
          "original_fact_id"        => fact_key,
          "boundary_key"            => "old_boundary_key",
          "boundary_output_fact_id" => "out-old",
          "boundary_receipt_id"     => "rec-old",
          "settlement_receipt_id"   => "sett-old",
          "compaction_receipt_id"   => "comp-old",
          "detail_status"           => "purged",
          "reference_role"          => "included_in_boundary"
        }
      )

      # Small sleep ensures second write has strictly later transaction_time.
      sleep(0.01)

      store.write(
        store: :ledger_fact_redirects, key: fact_key,
        value: {
          "original_fact_id"        => fact_key,
          "boundary_key"            => "new_boundary_key",
          "boundary_output_fact_id" => "out-new",
          "boundary_receipt_id"     => "rec-new",
          "settlement_receipt_id"   => "sett-new",
          "compaction_receipt_id"   => "comp-new",
          "detail_status"           => "purged",
          "reference_role"          => "included_in_boundary"
        }
      )

      result = l1.resolve_ref(fact_key, fidelity: :boundary)
      expect(result[:status]).to eq(:redirected)
      expect(result[:boundary_key]).to eq("new_boundary_key")
      expect(result[:evidence][:boundary_output_fact_id]).to eq("out-new")
    end
  end
end
