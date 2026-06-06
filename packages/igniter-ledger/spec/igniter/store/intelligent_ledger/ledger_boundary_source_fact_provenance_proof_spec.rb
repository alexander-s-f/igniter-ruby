# frozen_string_literal: true

require_relative "../../../spec_helper"
require "date"
require "time"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

# Intelligent Ledger — LedgerBoundary Source Fact Provenance Proof
#
# Research question:
#   Can a boundary say not only "this fact was included", but also
#   "this exact fact from this exact store, in this role, was included",
#   and does that statement survive restart/hydration?
#
# Scope:
#   - Snapshot value carries derived_from_fact_refs (id/store/role) alongside
#     the existing derived_from_fact_ids (backward compat).
#   - LedgerBoundary exposes source_fact_refs.
#   - Persisted boundary records and closure receipts carry source_fact_refs.
#   - Hydration restores source_fact_refs.
#   - compact_boundary redirects use original_store from refs (not "unknown").
#   - Redirects include source_role.
#   - resolve_ref(:raw) uses redirect.original_store for targeted lookup.
#   - Old-style boundary records (ids only) hydrate without crash.
#
#   Scenario 1:  snapshot includes derived_from_fact_refs with id/store/role
#   Scenario 2:  snapshot still includes derived_from_fact_ids (backward compat)
#   Scenario 3:  boundary.source_fact_refs has correct store names
#   Scenario 4:  boundary.source_fact_refs has correct role names
#   Scenario 5:  boundary.source_fact_ids still populated (backward compat)
#   Scenario 6:  persisted boundary record and closure receipt include source_fact_refs
#   Scenario 7:  compaction redirect has original_store from ref (not "unknown")
#   Scenario 8:  compaction redirect includes source_role from ref
#   Scenario 9:  resolve_ref(:raw) finds fact via targeted store (store hint used)
#   Scenario 10: hydration restores source_fact_refs on fresh ledger
#   Scenario 11: backward compat — old boundary with ids-only hydrates without crash
#   Scenario 12: boundary with order events produces refs with role "order_event"

IntelligentLedger = Igniter::Store::IntelligentLedger unless defined?(IntelligentLedger)

RSpec.describe "Intelligent Ledger: LedgerBoundary source fact provenance proof" do
  PROVENANCE_DATE     = Date.new(2026, 5, 4)
  PROVENANCE_SCHEDULE = {
    "1" => [["09:00", "17:00"]],
    "2" => [["09:00", "17:00"]],
    "3" => [["09:00", "17:00"]],
    "4" => [["09:00", "17:00"]],
    "5" => [["09:00", "17:00"]]
  }.freeze

  subject(:store) { Igniter::Store::IgniterStore.new }

  let(:company) { "company-provenance" }

  def ledger1 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)
  def ledger2 = IntelligentLedger::AvailabilityBoundaryLedger.new(store: store)

  def boundary_key_for(tid)
    IntelligentLedger::LedgerBoundary.key_for(
      company_id: company, technician_id: tid, date: PROVENANCE_DATE.to_s
    )
  end

  def setup_closed(l1, tid)
    l1.write_template(technician_id: tid, weekly_schedule: PROVENANCE_SCHEDULE)
    l1.open_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
    l1.close_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
  end

  def setup_compacted(l1, tid)
    setup_closed(l1, tid)
    bk = boundary_key_for(tid)
    l1.settle_boundary(bk)
    l1.compact_boundary(bk)
    l1
  end

  # ── Scenario 1 ───────────────────────────────────────────────────────────────

  describe "Scenario 1: snapshot includes derived_from_fact_refs with id/store/role" do
    let(:tid) { "tech-prov-s1" }

    before do
      l1 = ledger1
      l1.write_template(technician_id: tid, weekly_schedule: PROVENANCE_SCHEDULE)
    end

    let(:snapshot_fact) do
      l = ledger1
      l.write_template(technician_id: tid, weekly_schedule: PROVENANCE_SCHEDULE)
      l.open_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      r = l.close_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      r[:snapshot_fact]
    end

    it "snapshot value contains derived_from_fact_refs" do
      expect(snapshot_fact.value[:derived_from_fact_refs]).not_to be_nil
      expect(snapshot_fact.value[:derived_from_fact_refs]).to be_an(Array)
      expect(snapshot_fact.value[:derived_from_fact_refs]).not_to be_empty
    end

    it "each ref has :id, :store, :role fields" do
      refs = snapshot_fact.value[:derived_from_fact_refs]
      refs.each do |ref|
        expect(ref[:id]).not_to be_nil
        expect(ref[:store]).not_to be_nil
        expect(ref[:role]).not_to be_nil
      end
    end

    it "template ref has store availability_templates" do
      refs = snapshot_fact.value[:derived_from_fact_refs]
      template_ref = refs.find { |r| r[:role] == "template" }
      expect(template_ref).not_to be_nil
      expect(template_ref[:store]).to eq("availability_templates")
    end
  end

  # ── Scenario 2 ───────────────────────────────────────────────────────────────

  describe "Scenario 2: snapshot still includes derived_from_fact_ids (backward compat)" do
    let(:tid) { "tech-prov-s2" }

    let(:snapshot_fact) do
      l = ledger1
      l.write_template(technician_id: tid, weekly_schedule: PROVENANCE_SCHEDULE)
      l.open_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      r = l.close_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      r[:snapshot_fact]
    end

    it "snapshot value still has derived_from_fact_ids" do
      expect(snapshot_fact.value[:derived_from_fact_ids]).to be_an(Array)
      expect(snapshot_fact.value[:derived_from_fact_ids]).not_to be_empty
    end

    it "derived_from_fact_ids are a subset of ids in derived_from_fact_refs" do
      ids_from_list = snapshot_fact.value[:derived_from_fact_ids]
      ids_from_refs = snapshot_fact.value[:derived_from_fact_refs].map { |r| r[:id] }
      expect(ids_from_list).to match_array(ids_from_refs)
    end
  end

  # ── Scenario 3 ───────────────────────────────────────────────────────────────

  describe "Scenario 3: boundary.source_fact_refs has correct store names" do
    let(:tid) { "tech-prov-s3" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      @boundary = l1.find_boundary(bk)
    end

    it "source_fact_refs is not empty" do
      expect(@boundary.source_fact_refs).not_to be_empty
    end

    it "template ref has store availability_templates" do
      ref = @boundary.source_fact_refs.find { |r| r["role"] == "template" }
      expect(ref).not_to be_nil
      expect(ref["store"]).to eq("availability_templates")
    end

    it "each ref has string key 'store'" do
      @boundary.source_fact_refs.each do |ref|
        expect(ref.key?("store")).to be true
      end
    end
  end

  # ── Scenario 4 ───────────────────────────────────────────────────────────────

  describe "Scenario 4: boundary.source_fact_refs has correct role names" do
    let(:tid) { "tech-prov-s4" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      @boundary = l1.find_boundary(bk)
    end

    it "template ref has role 'template'" do
      roles = @boundary.source_fact_refs.map { |r| r["role"] }
      expect(roles).to include("template")
    end

    it "every ref has a non-nil role" do
      @boundary.source_fact_refs.each do |ref|
        expect(ref["role"]).not_to be_nil
      end
    end
  end

  # ── Scenario 5 ───────────────────────────────────────────────────────────────

  describe "Scenario 5: boundary.source_fact_ids still populated (backward compat)" do
    let(:tid) { "tech-prov-s5" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
      @boundary = l1.find_boundary(bk)
    end

    it "source_fact_ids is not empty" do
      expect(@boundary.source_fact_ids).not_to be_empty
    end

    it "source_fact_ids matches ids in source_fact_refs" do
      ids_from_ids  = @boundary.source_fact_ids
      ids_from_refs = @boundary.source_fact_refs.map { |r| r["id"] }
      expect(ids_from_ids).to match_array(ids_from_refs)
    end
  end

  # ── Scenario 6 ───────────────────────────────────────────────────────────────

  describe "Scenario 6: persisted boundary record and closure receipt include source_fact_refs" do
    let(:tid) { "tech-prov-s6" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
    end

    it "boundary record in :ledger_boundaries has source_fact_refs" do
      rec = store.history(store: :ledger_boundaries, key: bk).last
      expect(rec).not_to be_nil
      refs = rec.value[:source_fact_refs]
      expect(refs).to be_an(Array)
      expect(refs).not_to be_empty
    end

    it "boundary record source_fact_refs contain store and role" do
      rec  = store.history(store: :ledger_boundaries, key: bk).last
      refs = rec.value[:source_fact_refs]
      refs.each do |ref|
        expect(ref[:store]).not_to be_nil
        expect(ref[:role]).not_to be_nil
      end
    end

    it "closure receipt in :ledger_boundary_receipts has source_fact_refs" do
      rec = store.history(store: :ledger_boundary_receipts, key: bk).last
      expect(rec).not_to be_nil
      refs = rec.value[:source_fact_refs]
      expect(refs).to be_an(Array)
      expect(refs).not_to be_empty
    end
  end

  # ── Scenario 7 ───────────────────────────────────────────────────────────────

  describe "Scenario 7: compaction redirect has original_store from ref (not 'unknown')" do
    let(:tid) { "tech-prov-s7" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @boundary = l1.find_boundary(bk)
    end

    it "template redirect has original_store: availability_templates" do
      template_ref = @boundary.source_fact_refs.find { |r| r["role"] == "template" }
      expect(template_ref).not_to be_nil
      src_id = template_ref["id"]

      redirect = store.history(store: :ledger_fact_redirects, key: src_id).last
      expect(redirect).not_to be_nil
      expect(redirect.value[:original_store]).to eq("availability_templates")
    end

    it "no redirect has original_store: unknown when refs are available" do
      all_redirects = store.history(store: :ledger_fact_redirects)
      all_redirects.each do |r|
        expect(r.value[:original_store]).not_to eq("unknown")
      end
    end
  end

  # ── Scenario 8 ───────────────────────────────────────────────────────────────

  describe "Scenario 8: compaction redirect includes source_role from ref" do
    let(:tid) { "tech-prov-s8" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @boundary = l1.find_boundary(bk)
    end

    it "template redirect has source_role: template" do
      template_ref = @boundary.source_fact_refs.find { |r| r["role"] == "template" }
      src_id       = template_ref["id"]

      redirect = store.history(store: :ledger_fact_redirects, key: src_id).last
      expect(redirect.value[:source_role]).to eq("template")
    end

    it "every redirect has a non-nil source_role" do
      all_redirects = store.history(store: :ledger_fact_redirects)
      all_redirects.each do |r|
        expect(r.value[:source_role]).not_to be_nil
      end
    end
  end

  # ── Scenario 9 ───────────────────────────────────────────────────────────────

  describe "Scenario 9: resolve_ref(:raw) finds fact via targeted store hint" do
    let(:tid) { "tech-prov-s9" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_compacted(l1, tid)
      @boundary = l1.find_boundary(bk)
      @ledger   = l1
    end

    it "returns :ok for template fact (redirect has original_store: availability_templates)" do
      template_ref = @boundary.source_fact_refs.find { |r| r["role"] == "template" }
      src_id       = template_ref["id"]

      result = @ledger.resolve_ref(src_id, fidelity: :raw)
      expect(result[:status]).to eq(:ok)
      expect(result[:kind]).to eq(:raw_fact)
      expect(result[:fact].id).to eq(src_id)
    end

    it "targeted lookup is faithful: redirect.original_store matches actual fact store" do
      template_ref = @boundary.source_fact_refs.find { |r| r["role"] == "template" }
      src_id       = template_ref["id"]

      redirect = store.history(store: :ledger_fact_redirects, key: src_id).last
      original_store = redirect.value[:original_store].to_sym

      raw_fact = store.history(store: original_store).find { |f| f.id == src_id }
      expect(raw_fact).not_to be_nil
    end
  end

  # ── Scenario 10 ──────────────────────────────────────────────────────────────

  describe "Scenario 10: hydration restores source_fact_refs on fresh ledger" do
    let(:tid) { "tech-prov-s10" }
    let(:bk)  { boundary_key_for(tid) }

    before do
      l1 = ledger1
      setup_closed(l1, tid)
    end

    it "source_fact_refs is restored after hydration" do
      l2 = ledger2
      l2.hydrate_boundaries
      hydrated = l2.find_boundary(bk)
      expect(hydrated).not_to be_nil
      expect(hydrated.source_fact_refs).to be_an(Array)
      expect(hydrated.source_fact_refs).not_to be_empty
    end

    it "hydrated refs have correct store and role" do
      l2 = ledger2
      l2.hydrate_boundaries
      hydrated = l2.find_boundary(bk)
      template_ref = hydrated.source_fact_refs.find { |r| r["role"] == "template" }
      expect(template_ref).not_to be_nil
      expect(template_ref["store"]).to eq("availability_templates")
    end

    it "source_fact_ids is also restored and consistent with refs" do
      l2 = ledger2
      l2.hydrate_boundaries
      hydrated = l2.find_boundary(bk)
      ids_from_ids  = hydrated.source_fact_ids
      ids_from_refs = hydrated.source_fact_refs.map { |r| r["id"] }
      expect(ids_from_ids).to match_array(ids_from_refs)
    end
  end

  # ── Scenario 11 ──────────────────────────────────────────────────────────────

  describe "Scenario 11: backward compat — old boundary with ids-only hydrates without crash" do
    let(:tid) { "tech-prov-s11-oldstyle" }
    let(:bk)  { boundary_key_for(tid) }

    it "hydrates without crash and produces empty source_fact_refs" do
      l1 = ledger1

      # Manually write an old-style boundary record without source_fact_refs.
      output_fact  = store.write(store: :availability_snapshots,
                                 key:   "#{tid}/old-stub",
                                 value: { "available_seconds" => 0 })
      receipt_fact = store.write(store: :derivation_receipts,
                                 key:   output_fact.id,
                                 value: { "stub" => true })

      store.write(
        store: :ledger_boundaries, key: bk,
        value: {
          "boundary_key"    => bk,
          "output_fact_id"  => output_fact.id,
          "receipt_fact_id" => receipt_fact.id,
          "source_fact_ids" => ["old-fact-id-1"],
          "result_hash"     => "fake-hash",
          "detail_status"   => "full",
          "subject"         => { "company_id" => company, "technician_id" => tid,
                                 "date" => PROVENANCE_DATE.to_s },
          "closed_at"       => Time.now.iso8601(3),
          "rule_version"    => "1.0"
        }
      )
      store.write(
        store: :ledger_boundary_receipts, key: bk,
        value: { "boundary_key" => bk }
      )

      l2 = ledger2
      expect { l2.hydrate_boundaries }.not_to raise_error

      hydrated = l2.find_boundary(bk)
      expect(hydrated).not_to be_nil
      expect(hydrated.source_fact_ids).to eq(["old-fact-id-1"])
      expect(hydrated.source_fact_refs).to eq([])
    end
  end

  # ── Scenario 12 ──────────────────────────────────────────────────────────────

  describe "Scenario 12: boundary with order events produces refs with role order_event" do
    let(:tid)        { "tech-prov-s12" }
    let(:bk)         { boundary_key_for(tid) }
    let(:order_id)   { "order-prov-s12" }
    let(:order_start) { Time.utc(2026, 5, 4, 10, 0, 0).to_f }
    let(:order_end)   { Time.utc(2026, 5, 4, 11, 0, 0).to_f }

    before do
      l1 = ledger1
      l1.write_template(technician_id: tid, weekly_schedule: PROVENANCE_SCHEDULE)
      l1.write_order_event(order_id: order_id, technician_id: tid,
                           start_time: order_start, end_time: order_end)
      l1.open_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      l1.close_boundary(company_id: company, technician_id: tid, date: PROVENANCE_DATE)
      @boundary = l1.find_boundary(bk)
    end

    it "has an order_event ref" do
      order_ref = @boundary.source_fact_refs.find { |r| r["role"] == "order_event" }
      expect(order_ref).not_to be_nil
    end

    it "order_event ref has store order_events" do
      order_ref = @boundary.source_fact_refs.find { |r| r["role"] == "order_event" }
      expect(order_ref["store"]).to eq("order_events")
    end

    it "order_event ref id matches the fact in :order_events" do
      order_ref = @boundary.source_fact_refs.find { |r| r["role"] == "order_event" }
      raw = store.history(store: :order_events, key: order_id).last
      expect(raw).not_to be_nil
      expect(order_ref["id"]).to eq(raw.id)
    end
  end
end
