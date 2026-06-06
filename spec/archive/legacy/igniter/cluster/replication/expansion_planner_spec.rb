# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "igniter/core/memory"

RSpec.describe Igniter::Cluster::Replication::ExpansionPlanner do
  let(:topology) { Igniter::Cluster::Replication::NetworkTopology.new }

  def build_planner(**opts)
    described_class.new(topology: topology, **opts)
  end

  describe "#plan with no required capabilities and healthy topology" do
    it "returns a no_op plan" do
      plan = build_planner.plan
      expect(plan.no_op?).to be true
    end

    it "returns an ExpansionPlan" do
      expect(build_planner.plan).to be_a(Igniter::Cluster::Replication::ExpansionPlan)
    end
  end

  describe "#plan — retire unhealthy nodes" do
    before do
      topology.register(node_id: "n1", host: "10.0.0.1", capabilities: [:local_llm])
      topology.mark_unhealthy(node_id: "n1")
    end

    it "includes a :retire_node action" do
      actions = build_planner.plan.actions
      expect(actions.map { |a| a[:action] }).to include(:retire_node)
    end

    it "includes the node_id in the retire action" do
      action = build_planner.plan.actions.find { |a| a[:action] == :retire_node }
      expect(action[:node_id]).to eq("n1")
    end

    it "includes a rationale mentioning the unhealthy node" do
      rationale = build_planner.plan.rationale
      expect(rationale).to include("n1")
    end
  end

  describe "#plan — ensure required capabilities" do
    it "adds :replicate_capabilities when the query is absent and a host is available" do
      planner = build_planner(required_capabilities: [%i[local_llm container_runtime]], host_pool: ["10.0.0.2"])
      action  = planner.plan.actions.find { |a| a[:action] == :replicate_capabilities }
      expect(action).to include(host: "10.0.0.2")
      expect(action.dig(:query, :all_of)).to eq(%i[container_runtime local_llm])
    end

    it "does not add :replicate_capabilities when the query is already covered" do
      topology.register(node_id: "w1", host: "10.0.0.1", capabilities: %i[local_llm container_runtime])
      planner = build_planner(required_capabilities: [%i[local_llm container_runtime]], host_pool: ["10.0.0.2"])
      expect(planner.plan.actions.map { |a| a[:action] }).not_to include(:replicate_capabilities)
    end

    it "notes in rationale when a host is missing for the required query" do
      planner = build_planner(required_capabilities: [%i[local_llm container_runtime]], host_pool: [])
      rationale = planner.plan.rationale
      expect(rationale).to include("local_llm")
      expect(rationale).to include("no available host")
    end

    it "skips already-used hosts when assigning a new node" do
      topology.register(node_id: "n1", host: "10.0.0.1", capabilities: [:ruby])
      planner = build_planner(
        required_capabilities: [[:local_llm]],
        host_pool:             ["10.0.0.1", "10.0.0.2"]
      )
      action = planner.plan.actions.find { |a| a[:action] == :replicate_capabilities }
      expect(action[:host]).to eq("10.0.0.2")
    end
  end

  describe "#plan — failure signal from memory" do
    let(:store)  { Igniter::Memory::Stores::InMemory.new }
    let(:memory) do
      Igniter::Memory::AgentMemory.new(store: store, agent_id: "TestAgent")
    end

    before do
      4.times do
        store.record(
          agent_id: "TestAgent",
          type:     :replication_event,
          content:  "replication_failed: ...",
          outcome:  "failure"
        )
      end
    end

    it "mentions failure count in rationale when threshold exceeded" do
      planner = build_planner(memory: memory, failure_threshold: 3)
      expect(planner.plan.rationale).to include("recent replication failures")
    end

    it "does not mention failures when below threshold" do
      planner = build_planner(memory: memory, failure_threshold: 10)
      expect(planner.plan.rationale.to_s).not_to include("recent replication failures")
    end
  end

  describe "#plan — scale_signal episodes" do
    let(:store)  { Igniter::Memory::Stores::InMemory.new }
    let(:memory) do
      Igniter::Memory::AgentMemory.new(store: store, agent_id: "TestAgent")
    end

    before do
      store.record(
        agent_id: "TestAgent",
        type:     :scale_signal,
        content:  "scale_out:local_llm+container_runtime",
        outcome:  nil
      )
    end

    it "adds :replicate_capabilities action for the signalled query" do
      planner = build_planner(memory: memory, host_pool: ["10.0.0.5"])
      action  = planner.plan.actions.find { |a| a[:action] == :replicate_capabilities }
      expect(action).to include(host: "10.0.0.5")
      expect(action.dig(:query, :all_of)).to eq(%i[container_runtime local_llm])
    end

    it "ignores malformed scale_signal content" do
      store.record(agent_id: "TestAgent", type: :scale_signal, content: "bad:signal")
      planner = build_planner(memory: memory, host_pool: ["10.0.0.5"])
      replicate_actions = planner.plan.actions.select { |a| a[:action] == :replicate_capabilities }
      expect(replicate_actions.size).to eq(1)
    end
  end

  describe "#plan — LLM mode" do
    let(:llm_double) do
      double("LLM").tap do |d|
        allow(d).to receive(:call).and_return(
          actions:   [{ action: :replicate_capabilities, query: { all_of: [:local_llm] }, host: "10.0.0.9" }],
          rationale: "LLM says scale out"
        )
      end
    end

    it "delegates to the LLM and returns its plan" do
      planner = build_planner(llm: llm_double)
      plan    = planner.plan
      expect(plan.rationale).to eq("LLM says scale out")
      expect(plan.actions.first[:host]).to eq("10.0.0.9")
    end

    it "passes topology and required_capabilities to the LLM" do
      topology.register(node_id: "x", host: "10.0.0.1", capabilities: [:local_llm])
      planner = build_planner(llm: llm_double, required_capabilities: [[:container_runtime]])
      planner.plan
      expect(llm_double).to have_received(:call).with(
        hash_including(required_capabilities: [hash_including(all_of: [:container_runtime])])
      )
    end
  end

  describe "ExpansionPlan#no_op?" do
    it "returns true for a single :no_op action" do
      plan = Igniter::Cluster::Replication::ExpansionPlan.new(actions: [{ action: :no_op }])
      expect(plan.no_op?).to be true
    end

    it "returns false when real actions are present" do
      plan = Igniter::Cluster::Replication::ExpansionPlan.new(
        actions: [{ action: :replicate_capabilities, query: { all_of: [:local_llm] }, host: "x" }]
      )
      expect(plan.no_op?).to be false
    end
  end
end
