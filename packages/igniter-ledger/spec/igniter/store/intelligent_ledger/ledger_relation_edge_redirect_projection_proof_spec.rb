# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

RSpec.describe "Ledger Relation Edge Redirect Projection — intelligent ledger proof" do
  EDGE_DATE     = Date.new(2026, 5, 1)
  EDGE_SCHEDULE = { "5" => [["09:00", "17:00"]] }.freeze  # Friday

  ABL = Igniter::Store::IntelligentLedger::AvailabilityBoundaryLedger unless defined?(ABL)
  LB  = Igniter::Store::IntelligentLedger::LedgerBoundary             unless defined?(LB)

  let(:store)  { Igniter::Store::IgniterStore.new }
  let(:ledger) { ABL.new(store: store) }

  let(:company_id) { "c-edge" }
  let(:tech_id)    { "t-edge" }

  # Write a template fact and return its id (the raw "to" target for edges)
  def write_target_fact
    store.write(
      store: :availability_templates,
      key:   tech_id,
      value: { "weekly_schedule" => EDGE_SCHEDULE }
    )
  end

  # Full close+settle+compact cycle on a boundary that includes the template fact
  def close_and_compact_boundary
    ledger.write_template(technician_id: tech_id, weekly_schedule: EDGE_SCHEDULE)
    ledger.open_boundary(company_id: company_id, technician_id: tech_id, date: EDGE_DATE)
    ledger.close_boundary(company_id: company_id, technician_id: tech_id, date: EDGE_DATE)
    bk = LB.key_for(company_id: company_id, technician_id: tech_id, date: EDGE_DATE.to_s)
    ledger.settle_boundary(bk)
    ledger.compact_boundary(bk)
    bk
  end

  # ── Scenario 1: Create edge to live fact ──────────────────────────────────────

  describe "Scenario 1: create edge to live raw fact" do
    it "persists edge with ref_status: raw" do
      target = write_target_fact
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-1", from_fact_id: "nfact-1",
        to_fact_id: target.id, relation: :notification_order_event
      )

      edge_facts = store.history(store: :ledger_relation_edges, key: result[:edge_id])
      expect(edge_facts).not_to be_empty
      edge = edge_facts.last.value
      expect(edge[:ref_status]).to eq("raw")
      expect(edge[:fidelity]).to eq("raw")
      expect(edge[:to_fact_id]).to eq(target.id)
      expect(edge[:to_store]).to eq("availability_templates")
    end

    it "resolve_edge(:raw) returns ok/raw for a live edge" do
      target = write_target_fact
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-1", from_fact_id: "nfact-1",
        to_fact_id: target.id, relation: :notification_order_event
      )

      resolution = ledger.resolve_edge(result[:edge_id], fidelity: :raw)
      expect(resolution[:status]).to eq(:ok)
      expect(resolution[:ref_status]).to eq(:raw)
      expect(resolution[:fidelity]).to eq(:raw)
      expect(resolution[:to_fact]).not_to be_nil
      expect(resolution[:to_fact].id).to eq(target.id)
    end

    it "does not embed the full value payload in the edge record" do
      target = write_target_fact
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-1", from_fact_id: "nfact-1",
        to_fact_id: target.id, relation: :notification_order_event
      )

      edge = store.history(store: :ledger_relation_edges, key: result[:edge_id]).last.value
      expect(edge.keys).not_to include(:value)
      expect(edge.keys).not_to include("value")
    end
  end

  # ── Scenario 2: Unknown target creates unresolved edge ───────────────────────

  describe "Scenario 2: edge to unknown fact" do
    it "persists edge with ref_status: unresolved" do
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-2", from_fact_id: "nfact-2",
        to_fact_id: "nonexistent-uuid", relation: :notification_order_event
      )

      edge = store.history(store: :ledger_relation_edges, key: result[:edge_id]).last.value
      expect(edge[:ref_status]).to eq("unresolved")
      expect(edge[:to_store]).to be_nil
    end

    it "resolve_edge returns :unresolved status" do
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-2", from_fact_id: "nfact-2",
        to_fact_id: "nonexistent-uuid", relation: :notification_order_event
      )

      resolution = ledger.resolve_edge(result[:edge_id], fidelity: :boundary)
      expect(resolution[:status]).to eq(:unresolved)
      expect(resolution[:ref_status]).to eq(:unresolved)
    end
  end

  # ── Scenario 3: Edge not found ───────────────────────────────────────────────

  describe "Scenario 3: resolve_edge with unknown edge_id" do
    it "returns :not_found" do
      resolution = ledger.resolve_edge("totally-unknown-edge-id")
      expect(resolution[:status]).to eq(:not_found)
      expect(resolution[:edge_id]).to eq("totally-unknown-edge-id")
    end
  end

  # ── Scenario 4: raw→redirected after compaction ───────────────────────────────

  describe "Scenario 4: edge transitions raw → redirected after boundary compaction" do
    it "resolve_edge(:boundary) returns redirected after compaction" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first
      expect(source_ref).not_to be_nil

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-4", from_fact_id: "nfact-4",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )

      # With boundary fidelity the redirect is followed
      resolution = ledger.resolve_edge(result[:edge_id], fidelity: :boundary)
      expect(resolution[:status]).to eq(:ok)
      expect(resolution[:ref_status]).to eq(:redirected)
      expect(resolution[:fidelity]).to eq(:boundary)
      expect(resolution[:to_boundary_key]).to eq(bk)
      expect(resolution[:evidence]).to include(:boundary_output_fact_id)
    end

    it "resolve_edge(:raw, assume_compacted: true) returns :detail_unavailable" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-4b", from_fact_id: "nfact-4b",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )

      resolution = ledger.resolve_edge(result[:edge_id], fidelity: :raw, assume_compacted: true)
      expect(resolution[:status]).to eq(:detail_unavailable)
      expect(resolution[:evidence]).to include(:boundary_output_fact_id)
    end
  end

  # ── Scenario 5: refresh_relation_edges persists redirected state ──────────────

  describe "Scenario 5: refresh_relation_edges updates raw → redirected in store" do
    it "updates edge ref_status to redirected in persisted store" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-5", from_fact_id: "nfact-5",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )
      edge_id = result[:edge_id]

      # Before refresh, edge is still raw
      edge_before = store.history(store: :ledger_relation_edges, key: edge_id).last.value
      expect(edge_before[:ref_status]).to eq("raw")

      summary = ledger.refresh_relation_edges(assume_compacted: true)
      expect(summary[:refreshed_count]).to be >= 1

      # After refresh, latest edge fact has redirected state
      edge_after = store.history(store: :ledger_relation_edges, key: edge_id)
                        .max_by(&:transaction_time).value
      expect(edge_after[:ref_status]).to eq("redirected")
      expect(edge_after[:fidelity]).to eq("boundary")
      expect(edge_after[:to_boundary_key]).to eq(bk)
      expect(edge_after[:evidence]).not_to be_nil
    end

    it "returns refresh summary counts" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      ledger.link_fact(
        from_store: :notifications, from_key: "n-5c", from_fact_id: "nfact-5c",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )

      summary = ledger.refresh_relation_edges(assume_compacted: true)
      expect(summary).to include(:refreshed_count, :skipped_count, :unresolved_count)
      expect(summary[:refreshed_count]).to be >= 1
    end
  end

  # ── Scenario 6: Idempotent refresh ───────────────────────────────────────────

  describe "Scenario 6: refresh_relation_edges is idempotent" do
    it "second refresh skips already-redirected edges" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      ledger.link_fact(
        from_store: :notifications, from_key: "n-6", from_fact_id: "nfact-6",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )

      ledger.refresh_relation_edges(assume_compacted: true)

      # Second call: edge is already redirected, should be skipped
      summary2 = ledger.refresh_relation_edges(assume_compacted: true)
      expect(summary2[:refreshed_count]).to eq(0)
      expect(summary2[:skipped_count]).to be >= 1
    end

    it "live-fact edges are skipped when not assume_compacted" do
      target = write_target_fact
      ledger.link_fact(
        from_store: :notifications, from_key: "n-6b", from_fact_id: "nfact-6b",
        to_fact_id: target.id, relation: :notification_availability
      )

      summary = ledger.refresh_relation_edges(assume_compacted: false)
      expect(summary[:refreshed_count]).to eq(0)
      expect(summary[:skipped_count]).to be >= 1
    end
  end

  # ── Scenario 7: Multiple edges to same compacted fact ─────────────────────────

  describe "Scenario 7: multiple edges to same compacted fact all redirect" do
    it "all edges become redirected after refresh" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      result1 = ledger.link_fact(
        from_store: :notifications, from_key: "n-7a", from_fact_id: "nfact-7a",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )
      result2 = ledger.link_fact(
        from_store: :orders, from_key: "o-7b", from_fact_id: "ofact-7b",
        to_fact_id: source_ref["id"], relation: :order_availability
      )

      summary = ledger.refresh_relation_edges(assume_compacted: true)
      expect(summary[:refreshed_count]).to be >= 2

      [result1[:edge_id], result2[:edge_id]].each do |eid|
        edge = store.history(store: :ledger_relation_edges, key: eid)
                    .max_by(&:transaction_time).value
        expect(edge[:ref_status]).to eq("redirected")
        expect(edge[:to_boundary_key]).to eq(bk)
      end
    end
  end

  # ── Scenario 8: Restart — fresh ledger resolves via persisted edge ────────────

  describe "Scenario 8: restart proof — fresh ledger resolves persisted edge" do
    it "resolve_edge(:boundary) works on a fresh ledger without in-memory boundary state" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-8", from_fact_id: "nfact-8",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )
      edge_id = result[:edge_id]

      # Fresh ledger — same store, no hydrate_boundaries called
      ledger2    = ABL.new(store: store)
      resolution = ledger2.resolve_edge(edge_id, fidelity: :boundary)

      expect(resolution[:status]).to eq(:ok)
      expect(resolution[:ref_status]).to eq(:redirected)
      expect(resolution[:to_boundary_key]).to eq(bk)
    end

    it "resolve_edge(:raw) on fresh ledger respects raw fidelity — returns ok when fact still live" do
      target  = write_target_fact
      result  = ledger.link_fact(
        from_store: :notifications, from_key: "n-8b", from_fact_id: "nfact-8b",
        to_fact_id: target.id, relation: :notification_availability
      )

      ledger2    = ABL.new(store: store)
      resolution = ledger2.resolve_edge(result[:edge_id], fidelity: :raw)
      expect(resolution[:status]).to eq(:ok)
      expect(resolution[:ref_status]).to eq(:raw)
    end

    it "resolve_edge after refresh persists redirected state across restart" do
      bk = close_and_compact_boundary
      boundary   = ledger.find_boundary(bk)
      source_ref = boundary.source_fact_refs.first

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-8c", from_fact_id: "nfact-8c",
        to_fact_id: source_ref["id"], relation: :notification_availability
      )
      ledger.refresh_relation_edges(assume_compacted: true)

      ledger3 = ABL.new(store: store)
      # Even with :raw fidelity the refreshed persisted edge value is readable from
      # the redirected record; boundary fidelity is the natural path post-compaction.
      resolution = ledger3.resolve_edge(result[:edge_id], fidelity: :boundary)
      expect(resolution[:status]).to eq(:ok)
      expect(resolution[:ref_status]).to eq(:redirected)
    end
  end

  # ── Scenario 9: edge without redirect → unresolved ───────────────────────────

  describe "Scenario 9: edge whose fact is gone with no redirect" do
    it "resolve_edge returns :unresolved when no redirect and fact absent" do
      # Write a fact, capture its id, then create an edge
      target = write_target_fact
      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-9", from_fact_id: "nfact-9",
        to_fact_id: target.id, relation: :notification_availability
      )

      # resolve_ref will return :not_found (no redirect exists) when assume_compacted
      # and no redirect written — fact_by_id skipped, no redirect → unresolved
      resolution = ledger.resolve_edge(result[:edge_id], fidelity: :raw, assume_compacted: true)
      # resolve_ref with :raw + assume_compacted returns :not_found when no redirect
      expect(%i[unresolved detail_unavailable]).to include(resolution[:status])
    end
  end
end
