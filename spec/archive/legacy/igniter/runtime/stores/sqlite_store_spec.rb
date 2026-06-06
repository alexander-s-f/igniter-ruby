# frozen_string_literal: true

require "spec_helper"
require "igniter"

RSpec.describe Igniter::Runtime::Stores::SQLiteStore do
  subject(:store) { described_class.new(path: ":memory:") }

  let(:pending_snapshot) do
    {
      execution_id: "exec-1",
      graph: "LeadWorkflow",
      states: {
        crm_data: { status: "pending" }
      }
    }
  end

  let(:done_snapshot) do
    {
      execution_id: "exec-2",
      graph: "LeadWorkflow",
      states: {
        crm_data: { status: "succeeded" }
      }
    }
  end

  it "saves, fetches, and deletes snapshots" do
    expect(store.save(pending_snapshot)).to eq("exec-1")
    expect(store.exist?("exec-1")).to be(true)
    expect(store.fetch("exec-1")).to include("execution_id" => "exec-1", "graph" => "LeadWorkflow")

    store.delete("exec-1")
    expect(store.exist?("exec-1")).to be(false)
  end

  it "finds an execution by graph and correlation" do
    store.save(
      pending_snapshot,
      graph: "LeadWorkflow",
      correlation: { request_id: "req-1", company_id: "co-1" }
    )

    expect(
      store.find_by_correlation(
        graph: "LeadWorkflow",
        correlation: { company_id: "co-1", request_id: "req-1" }
      )
    ).to eq("exec-1")
  end

  it "lists all and pending execution ids" do
    store.save(pending_snapshot, graph: "LeadWorkflow")
    store.save(done_snapshot, graph: "LeadWorkflow")

    expect(store.list_all(graph: "LeadWorkflow")).to eq(%w[exec-1 exec-2])
    expect(store.list_pending(graph: "LeadWorkflow")).to eq(["exec-1"])
  end
end
