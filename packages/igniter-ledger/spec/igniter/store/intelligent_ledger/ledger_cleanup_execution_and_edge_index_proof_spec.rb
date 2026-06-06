# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

RSpec.describe "Ledger Cleanup Execution + Edge Index — intelligent ledger proof" do
  EXEC_DATE     = Date.new(2026, 5, 1)
  EXEC_SCHEDULE = { "5" => [["09:00", "17:00"]] }.freeze
  EXEC_COMPANY  = "c-exec"

  ABL = Igniter::Store::IntelligentLedger::AvailabilityBoundaryLedger unless defined?(ABL)
  LB  = Igniter::Store::IntelligentLedger::LedgerBoundary             unless defined?(LB)

  let(:store)  { Igniter::Store::IgniterStore.new }
  let(:ledger) { ABL.new(store: store) }
  let(:cutoff) { Time.utc(2026, 5, 2, 0, 0, 0) }

  def boundary_key_for(tid)
    LB.key_for(company_id: EXEC_COMPANY, technician_id: tid, date: EXEC_DATE.to_s)
  end

  def setup_settled(tid)
    ledger.write_template(technician_id: tid, weekly_schedule: EXEC_SCHEDULE)
    ledger.open_boundary(company_id: EXEC_COMPANY, technician_id: tid, date: EXEC_DATE)
    ledger.close_boundary(company_id: EXEC_COMPANY, technician_id: tid, date: EXEC_DATE)
    bk = boundary_key_for(tid)
    ledger.settle_boundary(bk)
    bk
  end

  def first_source_ref(bk)
    ledger.find_boundary(bk).source_fact_refs.first
  end

  def ready_plan(tid = "t-exec-rp")
    bk = setup_settled(tid)
    ledger.cleanup_plan(store: :order_events, before: cutoff,
                        require_reference_redirects: true)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCOPE A: Relation Edge Target Index
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Scope A — target index: link_fact writes index entry" do
    let(:tid) { "t-exec-a1" }

    it "link_fact writes an entry to :ledger_relation_edge_targets under to_fact_id" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      ledger.link_fact(
        from_store: :notifications, from_key: "n-a1", from_fact_id: "nfact-a1",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      entries = store.history(store: :ledger_relation_edge_targets, key: ref["id"])
      expect(entries).not_to be_empty
      value = entries.last.value
      expect(value[:to_fact_id]).to eq(ref["id"])
      expect(value[:ref_status]).to eq("raw")
    end

    it "index entry carries edge_id, from_store, relation" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-a1b", from_fact_id: "nfact-a1b",
        to_fact_id: ref["id"], relation: :test_relation
      )

      entry = store.history(store: :ledger_relation_edge_targets, key: ref["id"]).last.value
      expect(entry[:edge_id]).to   eq(result[:edge_id])
      expect(entry[:from_store]).to eq("notifications")
      expect(entry[:relation]).to   eq("test_relation")
    end

    it "unresolved edge (unknown target) is also indexed" do
      unknown_id = "unknown-fact-#{SecureRandom.hex(4)}"
      ledger.link_fact(
        from_store: :orders, from_key: "o-a1c", from_fact_id: "ofact-a1c",
        to_fact_id: unknown_id, relation: :order_ref
      )

      entries = store.history(store: :ledger_relation_edge_targets, key: unknown_id)
      expect(entries).not_to be_empty
      expect(entries.last.value[:ref_status]).to eq("unresolved")
    end
  end

  describe "Scope A — target index: multiple edges to same fact" do
    let(:tid) { "t-exec-a2" }

    it "two distinct edges to the same to_fact_id appear as two history entries" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      r1 = ledger.link_fact(
        from_store: :notifications, from_key: "n-a2a", from_fact_id: "nfact-a2a",
        to_fact_id: ref["id"], relation: :rel_a
      )
      r2 = ledger.link_fact(
        from_store: :orders, from_key: "o-a2b", from_fact_id: "ofact-a2b",
        to_fact_id: ref["id"], relation: :rel_b
      )

      entries = store.history(store: :ledger_relation_edge_targets, key: ref["id"])
      edge_ids = entries.map { |e| e.value[:edge_id] }
      expect(edge_ids).to include(r1[:edge_id], r2[:edge_id])
    end
  end

  describe "Scope A — target index: refresh_relation_edges updates index to redirected" do
    let(:tid) { "t-exec-a3" }

    it "after refresh, index entry for the edge shows ref_status: redirected" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-a3", from_fact_id: "nfact-a3",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      ledger.compact_boundary(bk)
      ledger.refresh_relation_edges(assume_compacted: true)

      entries = store.history(store: :ledger_relation_edge_targets, key: ref["id"])
      # Group by edge_id and take latest
      latest_for_edge = entries
        .select { |e| e.value[:edge_id] == result[:edge_id] }
        .max_by(&:transaction_time).value
      expect(latest_for_edge[:ref_status]).to eq("redirected")
    end

    it "after refresh, raw entry is superseded but still in history" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      ledger.link_fact(
        from_store: :notifications, from_key: "n-a3b", from_fact_id: "nfact-a3b",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      ledger.compact_boundary(bk)
      ledger.refresh_relation_edges(assume_compacted: true)

      entries = store.history(store: :ledger_relation_edge_targets, key: ref["id"])
      statuses = entries.map { |e| e.value[:ref_status] }
      expect(statuses).to include("raw", "redirected")
    end
  end

  describe "Scope A — guard parity: indexed lookup matches full-scan semantics" do
    let(:tid) { "t-exec-a4" }

    it "no external edges → ready (parity)" do
      setup_settled(tid)
      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      expect(plan[:status]).to eq(:ready)
      expect(plan[:blocking_relation_edges]).to be_empty
    end

    it "raw edge → blocked (parity)" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-a4", from_fact_id: "nfact-a4",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      expect(plan[:status]).to eq(:blocked)
      expect(plan[:blocking_relation_edges].map { |e| e[:to_fact_id] }).to include(ref["id"])
    end

    it "redirected edge → ready (parity)" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-a4r", from_fact_id: "nfact-a4r",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      ledger.compact_boundary(bk)
      ledger.refresh_relation_edges(assume_compacted: true)

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      expect(plan[:status]).to eq(:ready)
    end

    it "unresolved edge → blocked (parity)" do
      bk       = setup_settled(tid)
      boundary = ledger.find_boundary(bk)
      src_id   = boundary.source_fact_ids.first

      store.write(
        store:    :ledger_relation_edges,
        key:      "edge-unresolved-exec",
        value:    {
          "edge_id" => "edge-unresolved-exec", "relation" => "mystery",
          "from_store" => "sys", "from_key" => "x", "from_fact_id" => "xf",
          "to_store" => nil, "to_key" => nil, "to_fact_id" => src_id,
          "to_boundary_key" => nil, "ref_status" => "unresolved",
          "fidelity" => "raw", "evidence" => {}
        }
      )
      # Also write to target index (simulates link_fact for this edge)
      store.write(
        store:    :ledger_relation_edge_targets,
        key:      src_id,
        value:    {
          "to_fact_id" => src_id, "edge_id" => "edge-unresolved-exec",
          "from_store" => "sys", "from_fact_id" => "xf", "to_store" => nil,
          "to_boundary_key" => nil, "ref_status" => "unresolved",
          "relation" => "mystery", "evidence" => {}
        }
      )

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      expect(plan[:status]).to eq(:blocked)
      unresolved = plan[:blocking_relation_edges].select { |e| e[:ref_status] == :unresolved }
      expect(unresolved).not_to be_empty
    end
  end

  describe "Scope A — rebuild_relation_edge_target_index" do
    let(:tid) { "t-exec-a5" }

    it "rebuilds index from canonical :ledger_relation_edges history" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)

      result = ledger.link_fact(
        from_store: :notifications, from_key: "n-a5", from_fact_id: "nfact-a5",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      # Simulate missing index by using a fresh store that only has the canonical edges
      new_store = Igniter::Store::IgniterStore.new
      # Copy ledger_relation_edges to the new store (replay scenario)
      store.history(store: :ledger_relation_edges).each do |f|
        new_store.write(store: :ledger_relation_edges, key: f.key, value: f.value)
      end

      new_ledger = ABL.new(store: new_store)
      result2    = new_ledger.rebuild_relation_edge_target_index
      expect(result2[:rebuilt_count]).to be >= 1

      entries = new_store.history(store: :ledger_relation_edge_targets, key: ref["id"])
      expect(entries).not_to be_empty
      expect(entries.last.value[:edge_id]).to eq(result[:edge_id])
    end

    it "rebuild is idempotent — calling twice does not change guard results" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-a5b", from_fact_id: "nfact-a5b",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      ledger.rebuild_relation_edge_target_index
      ledger.rebuild_relation_edge_target_index

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      expect(plan[:status]).to eq(:blocked)
    end

    it "fresh ledger with existing store reads target index without rebuild" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-a5c", from_fact_id: "nfact-a5c",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      ledger2 = ABL.new(store: store)
      ledger2.hydrate_boundaries

      plan = ledger2.cleanup_plan(store: :order_events, before: cutoff,
                                  require_reference_redirects: true)
      expect(plan[:status]).to eq(:blocked)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # SCOPE B: Cleanup Execution Receipt
  # ─────────────────────────────────────────────────────────────────────────────

  describe "Scope B — execute_cleanup_plan: ready plan writes receipt" do
    let(:tid) { "t-exec-b1" }

    it "returns status: :executed_noop" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)
      expect(result[:status]).to eq(:executed_noop)
    end

    it "receipt is written to :ledger_cleanup_execution_receipts" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)

      receipts = store.history(store: :ledger_cleanup_execution_receipts,
                               key: result[:plan_hash])
      expect(receipts).not_to be_empty
      stored = receipts.last.value
      expect(stored[:status]).to eq("executed_noop")
    end

    it "receipt includes store, before, plan_hash" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)

      stored = store.history(store: :ledger_cleanup_execution_receipts,
                             key: result[:plan_hash]).last.value
      expect(stored[:store]).to  eq(plan[:store].to_s)
      expect(stored[:before]).to eq(plan[:before].to_s)
      expect(stored[:plan_hash]).to eq(result[:plan_hash])
    end

    it "receipt includes executed_at timestamp" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)

      stored = store.history(store: :ledger_cleanup_execution_receipts,
                             key: result[:plan_hash]).last.value
      expect(stored[:executed_at]).not_to be_nil
    end

    it "deduplicated: false on first execution" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)
      expect(result[:deduplicated]).to eq(false)
    end
  end

  describe "Scope B — execute_cleanup_plan: blocked plan is refused" do
    let(:tid) { "t-exec-b2" }

    it "returns status: :blocked when plan is blocked" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-b2", from_fact_id: "nfact-b2",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      plan   = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                   require_reference_redirects: true)
      result = ledger.execute_cleanup_plan(plan)
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to  eq(:plan_not_ready)
    end

    it "no receipt is written for a blocked plan" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-b2b", from_fact_id: "nfact-b2b",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)
      ledger.execute_cleanup_plan(plan)

      all_receipts = store.history(store: :ledger_cleanup_execution_receipts)
      expect(all_receipts).to be_empty
    end

    it "blocking_boundaries and blocking_relation_edges are included in blocked result" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-b2c", from_fact_id: "nfact-b2c",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      plan   = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                   require_reference_redirects: true)
      result = ledger.execute_cleanup_plan(plan)
      expect(result[:blocking_boundaries]).to include(bk)
      expect(result[:blocking_relation_edges]).not_to be_empty
    end
  end

  describe "Scope B — execute_cleanup_plan: idempotency" do
    let(:tid) { "t-exec-b3" }

    it "second execution returns deduplicated: true" do
      plan = ready_plan(tid)
      ledger.execute_cleanup_plan(plan)
      result2 = ledger.execute_cleanup_plan(plan)
      expect(result2[:status]).to      eq(:executed_noop)
      expect(result2[:deduplicated]).to eq(true)
    end

    it "second execution does not append a new receipt record" do
      plan = ready_plan(tid)
      ledger.execute_cleanup_plan(plan)

      hash     = ledger.send(:stable_plan_hash, plan)
      receipts_after_first = store.history(store: :ledger_cleanup_execution_receipts, key: hash).size

      ledger.execute_cleanup_plan(plan)

      receipts_after_second = store.history(store: :ledger_cleanup_execution_receipts, key: hash).size
      expect(receipts_after_second).to eq(receipts_after_first)
    end

    it "two different scopes produce different plan_hashes" do
      bk1 = setup_settled("t-exec-b3-x")
      bk2 = setup_settled("t-exec-b3-y")

      plan_a = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                   require_reference_redirects: true)
      # change cutoff so receipts_to_keep list differs
      plan_b = ledger.cleanup_plan(store: :order_events,
                                   before: Time.utc(2026, 5, 3, 0, 0, 0),
                                   require_reference_redirects: true)

      hash_a = ledger.send(:stable_plan_hash, plan_a)
      hash_b = ledger.send(:stable_plan_hash, plan_b)
      expect(hash_a).not_to eq(hash_b)
    end
  end

  describe "Scope B — execute_cleanup_plan: restart / hydration idempotency" do
    let(:tid) { "t-exec-b4" }

    it "fresh ledger observes existing receipt and returns deduplicated" do
      plan   = ready_plan(tid)
      result = ledger.execute_cleanup_plan(plan)

      ledger2 = ABL.new(store: store)
      ledger2.hydrate_boundaries

      # Re-compute plan from fresh ledger (same store, same boundaries)
      plan2   = ledger2.cleanup_plan(store: :order_events, before: cutoff,
                                     require_reference_redirects: true)
      result2 = ledger2.execute_cleanup_plan(plan2)

      expect(result2[:status]).to      eq(:executed_noop)
      expect(result2[:deduplicated]).to eq(true)
      expect(result2[:plan_hash]).to    eq(result[:plan_hash])
    end
  end

  describe "Scope B — execute_cleanup_plan: blocked → guard passes → execute succeeds" do
    let(:tid) { "t-exec-b5" }

    it "after edge redirect, plan becomes ready and receipt is written" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-b5", from_fact_id: "nfact-b5",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      blocked_plan   = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                           require_reference_redirects: true)
      blocked_result = ledger.execute_cleanup_plan(blocked_plan)
      expect(blocked_result[:status]).to eq(:blocked)

      # Now compact and refresh so the edge becomes redirected
      ledger.compact_boundary(bk)
      ledger.refresh_relation_edges(assume_compacted: true)

      ready_plan_val = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                           require_reference_redirects: true)
      expect(ready_plan_val[:status]).to eq(:ready)

      exec_result = ledger.execute_cleanup_plan(ready_plan_val)
      expect(exec_result[:status]).to eq(:executed_noop)
      expect(exec_result[:deduplicated]).to eq(false)

      receipts = store.history(store: :ledger_cleanup_execution_receipts,
                               key: exec_result[:plan_hash])
      expect(receipts).not_to be_empty
    end

    it "blocked receipt does not interfere with later successful idempotency" do
      bk  = setup_settled(tid)
      ref = first_source_ref(bk)
      ledger.link_fact(
        from_store: :notifications, from_key: "n-b5b", from_fact_id: "nfact-b5b",
        to_fact_id: ref["id"], relation: :notification_availability
      )

      blocked_plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                         require_reference_redirects: true)
      ledger.execute_cleanup_plan(blocked_plan)

      ledger.compact_boundary(bk)
      ledger.refresh_relation_edges(assume_compacted: true)

      ready_plan_val = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                           require_reference_redirects: true)
      r1 = ledger.execute_cleanup_plan(ready_plan_val)
      r2 = ledger.execute_cleanup_plan(ready_plan_val)

      expect(r1[:status]).to      eq(:executed_noop)
      expect(r1[:deduplicated]).to eq(false)
      expect(r2[:deduplicated]).to eq(true)
    end
  end
end
