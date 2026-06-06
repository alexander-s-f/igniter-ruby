# frozen_string_literal: true

require "spec_helper"

RSpec.describe "IgniterStore#prune_fact_ids" do
  let(:store) { Igniter::Store::IgniterStore.new }

  def write_fact(key, value, s: :things)
    store.write(store: s, key: key, value: value)
  end

  # ── Basic prune behavior ───────────────────────────────────────────────────

  it "removes the fact from the live fact_id_index" do
    f = write_fact("k1", { v: 1 })
    store.prune_fact_ids(fact_ids: [f.id], reason: :test)
    expect(store.fact_by_id(f.id)).to be_nil
  end

  it "returns status: :ok with pruned_count" do
    f = write_fact("k2", { v: 2 })
    result = store.prune_fact_ids(fact_ids: [f.id], reason: :test)
    expect(result[:status]).to       eq(:ok)
    expect(result[:pruned_count]).to eq(1)
    expect(result[:missing_count]).to eq(0)
  end

  it "store remains queryable for other facts after prune" do
    write_fact("keep", { v: 10 })
    drop = write_fact("drop", { v: 99 })

    store.prune_fact_ids(fact_ids: [drop.id], reason: :test)

    expect(store.read(store: :things, key: "keep")).to include(v: 10)
    expect(store.read(store: :things, key: "drop")).to be_nil
  end

  it "pruned fact history is empty" do
    f = write_fact("gone", { v: 1 })
    store.prune_fact_ids(fact_ids: [f.id], reason: :test)
    expect(store.history(store: :things, key: "gone")).to be_empty
  end

  it "prune_fact_refs in receipt are compact (no full value payload)" do
    f = write_fact("k3", { big_payload: "x" * 1000 })
    result = store.prune_fact_ids(fact_ids: [f.id], reason: :test)

    ref = result[:pruned_fact_refs].first
    expect(ref).to include(:id, :store, :key, :transaction_time, :value_hash)
    expect(ref).not_to have_key(:value)
  end

  # ── Prune receipt ──────────────────────────────────────────────────────────

  it "writes a prune receipt to :__fact_prune_receipts" do
    f = write_fact("k4", { v: 1 })
    result = store.prune_fact_ids(fact_ids: [f.id], reason: :boundary_physical_purge,
                                  metadata: { source: "test" })

    receipts = store.history(store: :__fact_prune_receipts)
    expect(receipts).not_to be_empty
    r = receipts.last.value
    expect(r[:reason]).to         eq(:boundary_physical_purge)
    expect(r[:pruned_count]).to   eq(1)
    expect(r[:metadata]).to       include(source: "test")
  end

  it "receipt is written before log rebuild (survives the prune)" do
    f = write_fact("k5", { v: 1 })
    result = store.prune_fact_ids(fact_ids: [f.id], reason: :test)

    receipt_id = result[:receipt_id]
    expect(store.fact_by_id(receipt_id)).not_to be_nil
  end

  # ── Missing IDs ───────────────────────────────────────────────────────────

  it "missing fact ids are reported, not fatal" do
    result = store.prune_fact_ids(fact_ids: ["nonexistent-id"], reason: :test)
    expect(result[:status]).to        eq(:ok)
    expect(result[:missing_count]).to eq(1)
    expect(result[:missing_ids]).to   include("nonexistent-id")
    expect(result[:pruned_count]).to  eq(0)
  end

  it "mix of existing and missing ids: existing pruned, missing reported" do
    f = write_fact("real", { v: 1 })
    result = store.prune_fact_ids(fact_ids: [f.id, "fake-id"], reason: :test)
    expect(result[:pruned_count]).to  eq(1)
    expect(result[:missing_count]).to eq(1)
  end

  # ── Unsupported backend ───────────────────────────────────────────────────

  it "returns status: :unsupported when backend does not support replace_with_snapshot!" do
    # Supports write_fact (needed by store#write) but has no replace_with_snapshot!.
    fake_backend = Object.new
    def fake_backend.write_fact(_fact); end

    s      = Igniter::Store::IgniterStore.new(backend: fake_backend)
    result = s.prune_fact_ids(fact_ids: ["any-id"], reason: :test)
    expect(result[:status]).to eq(:unsupported)
    expect(result[:reason]).to eq(:backend_does_not_support_exact_prune)
  end

  it "in-memory store (no backend) executes prune without durability" do
    # backend: nil means no persistence — prune is in-memory only
    f = write_fact("mem", { v: 1 })
    result = store.prune_fact_ids(fact_ids: [f.id], reason: :test)
    expect(result[:status]).to eq(:ok)
    expect(store.fact_by_id(f.id)).to be_nil
  end
end
