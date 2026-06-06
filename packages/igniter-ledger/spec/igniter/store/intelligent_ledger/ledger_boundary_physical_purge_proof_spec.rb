# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../../../examples/intelligent_ledger/availability_boundary_ledger"

RSpec.describe "Ledger Boundary Physical Purge Barrier — intelligent ledger proof" do
  PURGE_DATE     = Date.new(2026, 5, 1)
  PURGE_SCHEDULE = { "5" => [["09:00", "17:00"]] }.freeze
  PURGE_COMPANY  = "c-purge"

  ABL = Igniter::Store::IntelligentLedger::AvailabilityBoundaryLedger unless defined?(ABL)
  LB  = Igniter::Store::IntelligentLedger::LedgerBoundary             unless defined?(LB)

  let(:store)  { Igniter::Store::IgniterStore.new }
  let(:ledger) { ABL.new(store: store) }
  let(:cutoff) { Time.utc(2026, 5, 2, 0, 0, 0) }

  def boundary_key_for(tid)
    LB.key_for(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE.to_s)
  end

  # Full lifecycle: open → close → settle → compact → execute cleanup plan
  # Returns { boundary_key:, plan:, exec_result: }
  def setup_ready_to_purge(tid)
    ledger.write_template(technician_id: tid, weekly_schedule: PURGE_SCHEDULE)
    ledger.open_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
    ledger.close_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
    bk = boundary_key_for(tid)
    ledger.settle_boundary(bk)
    ledger.compact_boundary(bk)
    ledger.refresh_relation_edges(assume_compacted: true)

    plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                               require_reference_redirects: true)
    expect(plan[:status]).to eq(:ready), "test setup: expected ready plan, got #{plan.inspect}"

    exec_result = ledger.execute_cleanup_plan(plan)
    expect(exec_result[:status]).to eq(:executed_noop), "test setup: expected executed_noop"

    { boundary_key: bk, plan: plan, exec_result: exec_result }
  end

  def source_fact_ids_for(bk)
    ledger.find_boundary(bk).source_fact_ids
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Dry run
  # ─────────────────────────────────────────────────────────────────────────────

  describe "dry_run: true — returns intent, removes nothing" do
    let(:tid) { "t-purge-dry1" }

    it "returns status: :ready and lists fact_ids_to_prune" do
      ctx = setup_ready_to_purge(tid)
      result = ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash],
                                              dry_run: true)
      expect(result[:status]).to     eq(:ready)
      expect(result[:dry_run]).to    eq(true)
      expect(result[:fact_ids_to_prune]).not_to be_empty
      expect(result[:blockers]).to   be_empty
    end

    it "source facts still exist in store after dry run" do
      ctx        = setup_ready_to_purge(tid)
      source_ids = source_fact_ids_for(ctx[:boundary_key])

      ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash],
                                     dry_run: true)

      source_ids.each do |id|
        expect(store.fact_by_id(id)).not_to be_nil, "expected fact #{id} to still exist after dry run"
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Actual purge (in-memory store)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "actual purge (dry_run: false)" do
    let(:tid) { "t-purge-act1" }

    it "returns status: :purged" do
      ctx    = setup_ready_to_purge(tid)
      result = ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])
      expect(result[:status]).to eq(:purged)
    end

    it "source facts are removed from live fact_id_index" do
      ctx        = setup_ready_to_purge(tid)
      source_ids = source_fact_ids_for(ctx[:boundary_key])

      ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])

      source_ids.each do |id|
        expect(store.fact_by_id(id)).to be_nil, "expected fact #{id} to be gone after purge"
      end
    end

    it "boundary replay (ledger.replay) still returns the boundary output" do
      ctx = setup_ready_to_purge(tid)
      ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])

      result = ledger.replay(ctx[:boundary_key])
      expect(result[:status]).to    eq(:ok)
      expect(result[:fidelity]).to  eq(:boundary)
      expect(result[:output]).not_to be_nil
    end

    it "full_replay returns :detail_unavailable after purge" do
      ctx = setup_ready_to_purge(tid)
      ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])

      result = ledger.full_replay(
        company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE
      )
      expect(result[:status]).to eq(:detail_unavailable)
    end

    it "fact redirects remain intact after purge" do
      ctx        = setup_ready_to_purge(tid)
      source_ids = source_fact_ids_for(ctx[:boundary_key])

      ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])

      source_ids.each do |id|
        ref_result = ledger.resolve_ref(id, fidelity: :boundary)
        expect(ref_result[:status]).to eq(:redirected),
          "expected redirect for fact #{id} to survive purge"
      end
    end

    it "physical purge receipt is written to :ledger_physical_purge_receipts" do
      ctx    = setup_ready_to_purge(tid)
      result = ledger.purge_cleanup_execution(plan_hash: ctx[:exec_result][:plan_hash])

      receipts = store.history(store: :ledger_physical_purge_receipts,
                               key: ctx[:exec_result][:plan_hash])
      expect(receipts).not_to be_empty
      stored = receipts.last.value
      expect(stored[:status]).to   eq("purged")
      expect(stored[:plan_hash]).to eq(ctx[:exec_result][:plan_hash])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Safety blockers
  # ─────────────────────────────────────────────────────────────────────────────

  describe "blocked: missing execution receipt" do
    it "returns :cleanup_execution_receipt_missing" do
      result = ledger.purge_cleanup_execution(plan_hash: "nonexistent-hash")
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to eq(:cleanup_execution_receipt_missing)
    end
  end

  describe "blocked: boundary not compacted" do
    let(:tid) { "t-purge-blk1" }

    it "returns :boundary_compaction_required" do
      ledger.write_template(technician_id: tid, weekly_schedule: PURGE_SCHEDULE)
      ledger.open_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      ledger.close_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      bk = boundary_key_for(tid)
      ledger.settle_boundary(bk)
      # NOT compacted

      plan = ledger.cleanup_plan(store: :order_events, before: cutoff,
                                 require_reference_redirects: true)

      # force-write a fake execution receipt for this plan hash so we can test the compaction guard
      plan_hash = ledger.send(:stable_plan_hash, plan)
      store.write(
        store: :ledger_cleanup_execution_receipts,
        key:   plan_hash,
        value: { "status" => "executed_noop", "boundary_keys" => [bk],
                 "store" => "order_events", "before" => cutoff.iso8601,
                 "fidelity" => "boundary", "require_reference_redirects" => true,
                 "receipts_to_keep" => [], "executed_at" => Time.now.utc.iso8601 }
      )

      result = ledger.purge_cleanup_execution(plan_hash: plan_hash)
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to eq(:boundary_compaction_required)
    end
  end

  describe "blocked: redirect missing for source fact" do
    let(:tid) { "t-purge-blk2" }

    it "returns :fact_redirect_missing when a source fact has no redirect" do
      ctx        = setup_ready_to_purge(tid)
      bk         = ctx[:boundary_key]
      source_ids = source_fact_ids_for(bk)

      # Remove redirect for one source fact to simulate missing redirect
      # Do this by creating a ledger with a fake boundary that has a non-redirected fact
      # We'll use a fake plan_hash pointing at a boundary with a source_fact_id
      # that has no redirect entry.
      # Easiest: inject a source_fact_id that has no redirect via direct store manipulation.
      fake_fact_id = "fake-src-#{SecureRandom.hex(4)}"

      # Patch the boundary's source_fact_ids in-memory
      boundary = ledger.find_boundary(bk)
      original_ids = boundary.source_fact_ids
      boundary.instance_variable_set(:@source_fact_ids, (original_ids + [fake_fact_id]).freeze)

      # Rebuild a plan hash reflecting the new state
      plan_hash = ctx[:exec_result][:plan_hash]

      result = ledger.purge_cleanup_execution(plan_hash: plan_hash)
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to eq(:fact_redirect_missing)

      # Restore
      boundary.instance_variable_set(:@source_fact_ids, original_ids)
    end
  end

  describe "blocked: reference guard fails" do
    let(:tid) { "t-purge-blk3" }

    it "returns :reference_guard_failed when a raw edge still points at a source fact" do
      ctx        = setup_ready_to_purge(tid)
      bk         = ctx[:boundary_key]
      plan_hash  = ctx[:exec_result][:plan_hash]
      source_ids = source_fact_ids_for(bk)

      # Inject a raw edge to a source fact AFTER the plan was executed
      src_id = source_ids.first
      ledger.link_fact(
        from_store: :notifications, from_key: "n-blk3", from_fact_id: "nfact-blk3",
        to_fact_id: src_id, relation: :notification_availability
      )

      result = ledger.purge_cleanup_execution(plan_hash: plan_hash)
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to eq(:reference_guard_failed)
    end
  end

  describe "blocked: store prune unsupported" do
    let(:tid) { "t-purge-blk4" }

    it "returns :store_prune_unsupported for a backend without replace_with_snapshot!" do
      # Has write_fact (needed by store#write) but no replace_with_snapshot!.
      unsupported = Object.new
      def unsupported.write_fact(_fact); end

      bad_store  = Igniter::Store::IgniterStore.new(backend: unsupported)
      bad_ledger = ABL.new(store: bad_store)

      bad_ledger.write_template(technician_id: tid, weekly_schedule: PURGE_SCHEDULE)
      bad_ledger.open_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      bad_ledger.close_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      bk = boundary_key_for(tid)
      bad_ledger.settle_boundary(bk)
      bad_ledger.compact_boundary(bk)
      bad_ledger.refresh_relation_edges(assume_compacted: true)

      plan = bad_ledger.cleanup_plan(store: :order_events, before: cutoff,
                                     require_reference_redirects: true)
      exec_result = bad_ledger.execute_cleanup_plan(plan)

      result = bad_ledger.purge_cleanup_execution(plan_hash: exec_result[:plan_hash])
      expect(result[:status]).to eq(:blocked)
      expect(result[:reason]).to eq(:store_prune_unsupported)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Idempotency
  # ─────────────────────────────────────────────────────────────────────────────

  describe "idempotency" do
    let(:tid) { "t-purge-idem" }

    it "second purge returns status: :purged, deduplicated: true" do
      ctx = setup_ready_to_purge(tid)
      h   = ctx[:exec_result][:plan_hash]

      ledger.purge_cleanup_execution(plan_hash: h)
      result2 = ledger.purge_cleanup_execution(plan_hash: h)

      expect(result2[:status]).to       eq(:purged)
      expect(result2[:deduplicated]).to eq(true)
    end

    it "second purge does not create a duplicate physical purge receipt" do
      ctx = setup_ready_to_purge(tid)
      h   = ctx[:exec_result][:plan_hash]

      ledger.purge_cleanup_execution(plan_hash: h)
      count_after_first = store.history(store: :ledger_physical_purge_receipts, key: h).size

      ledger.purge_cleanup_execution(plan_hash: h)
      count_after_second = store.history(store: :ledger_physical_purge_receipts, key: h).size

      expect(count_after_second).to eq(count_after_first)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # File-backed reopen (replay barrier)
  # ─────────────────────────────────────────────────────────────────────────────

  describe "file-backed reopen: pruned facts do not resurface" do
    let(:dir)  { Dir.mktmpdir("igniter_ledger_purge_spec") }
    let(:path) { File.join(dir, "ledger.wal") }

    after { FileUtils.rm_rf(dir) }

    let(:file_store)  { Igniter::Store.open(path) }
    let(:file_ledger) { ABL.new(store: file_store) }
    let(:tid)         { "t-purge-file1" }

    it "source facts are absent after purge + close + reopen" do
      file_ledger.write_template(technician_id: tid, weekly_schedule: PURGE_SCHEDULE)
      file_ledger.open_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      file_ledger.close_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      bk = boundary_key_for(tid)
      file_ledger.settle_boundary(bk)
      file_ledger.compact_boundary(bk)
      file_ledger.refresh_relation_edges(assume_compacted: true)

      plan = file_ledger.cleanup_plan(store: :order_events, before: cutoff,
                                      require_reference_redirects: true)
      exec = file_ledger.execute_cleanup_plan(plan)

      source_ids = file_ledger.find_boundary(bk).source_fact_ids

      file_ledger.purge_cleanup_execution(plan_hash: exec[:plan_hash])
      file_store.instance_variable_get(:@backend).close

      # Reopen
      s2 = Igniter::Store.open(path)
      source_ids.each do |id|
        expect(s2.fact_by_id(id)).to be_nil,
          "source fact #{id} should NOT return after purge + reopen"
      end
    end

    it "boundary replay and redirects work after purge + reopen" do
      file_ledger.write_template(technician_id: tid, weekly_schedule: PURGE_SCHEDULE)
      file_ledger.open_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      file_ledger.close_boundary(company_id: PURGE_COMPANY, technician_id: tid, date: PURGE_DATE)
      bk = boundary_key_for(tid)
      file_ledger.settle_boundary(bk)
      file_ledger.compact_boundary(bk)
      file_ledger.refresh_relation_edges(assume_compacted: true)

      plan = file_ledger.cleanup_plan(store: :order_events, before: cutoff,
                                      require_reference_redirects: true)
      exec = file_ledger.execute_cleanup_plan(plan)

      source_ids = file_ledger.find_boundary(bk).source_fact_ids
      file_ledger.purge_cleanup_execution(plan_hash: exec[:plan_hash])
      file_store.instance_variable_get(:@backend).close

      # Reopen
      s2       = Igniter::Store.open(path)
      ledger2  = ABL.new(store: s2)
      ledger2.hydrate_boundaries

      # Boundary replay still works
      replay = ledger2.replay(bk)
      expect(replay[:status]).to   eq(:ok)
      expect(replay[:fidelity]).to eq(:boundary)

      # Redirects survive reopen
      source_ids.each do |id|
        ref = ledger2.resolve_ref(id, fidelity: :boundary)
        expect(ref[:status]).to eq(:redirected),
          "redirect for fact #{id} should survive purge + reopen"
      end
    end
  end
end
