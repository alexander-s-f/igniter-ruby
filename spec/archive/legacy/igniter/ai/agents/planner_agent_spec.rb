# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::PlannerAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  let(:simple_handler) { ->(step:, index:, context:, results:) { "result:#{step}" } }

  # ── :plan ────────────────────────────────────────────────────────────────

  describe "on :plan — rule-based fallback" do
    it "creates a single-step plan from the goal when no planner configured" do
      result = call_handler(:plan, payload: { goal: "Deploy the app" })
      expect(result[:plan].size).to eq(1)
      expect(result[:plan].first.description).to eq("Deploy the app")
    end

    it "resets cursor and results" do
      state  = call_handler(:plan, payload: { goal: "Old goal" })
      state  = call_handler(:execute_next, state: state,
        payload: { step_handler: simple_handler })
      result = call_handler(:plan, state: state, payload: { goal: "New goal" })
      expect(result[:current_step]).to eq(0)
      expect(result[:results]).to be_empty
    end

    it "stores goal and context" do
      result = call_handler(:plan, payload: { goal: "G", context: { env: :prod } })
      expect(result[:goal]).to eq("G")
      expect(result[:context]).to eq({ env: :prod })
    end
  end

  describe "on :plan — with planner callable" do
    it "uses Array return from planner" do
      planner = ->(goal:, context:) { ["Step A", "Step B", "Step C"] }
      result  = call_handler(:plan, payload: { goal: "Build", planner: planner })
      expect(result[:plan].map(&:description)).to eq(["Step A", "Step B", "Step C"])
    end

    it "parses numbered list from String return" do
      planner = ->(goal:, context:) { "1. Fetch data\n2. Transform\n3. Load" }
      result  = call_handler(:plan, payload: { goal: "ETL", planner: planner })
      expect(result[:plan].map(&:description)).to eq(["Fetch data", "Transform", "Load"])
    end

    it "extracts steps from Hash return with :steps key" do
      planner = ->(goal:, context:) { { steps: ["Alpha", "Beta"] } }
      result  = call_handler(:plan, payload: { goal: "g", planner: planner })
      expect(result[:plan].map(&:description)).to eq(["Alpha", "Beta"])
    end

    it "initialises all steps with :pending status" do
      planner = ->(goal:, context:) { ["X", "Y"] }
      result  = call_handler(:plan, payload: { goal: "g", planner: planner })
      expect(result[:plan].map(&:status)).to all(eq(:pending))
    end
  end

  # ── :execute_next ─────────────────────────────────────────────────────────

  describe "on :execute_next" do
    let(:planned_state) do
      call_handler(:plan, payload: { goal: "multi", planner: ->(goal:, context:) { %w[A B C] } })
    end

    it "executes the first step and advances cursor" do
      result = call_handler(:execute_next, state: planned_state,
        payload: { step_handler: simple_handler })
      expect(result[:current_step]).to eq(1)
      expect(result[:plan].first.status).to eq(:done)
    end

    it "accumulates results" do
      s1 = call_handler(:execute_next, state: planned_state,
        payload: { step_handler: simple_handler })
      s2 = call_handler(:execute_next, state: s1,
        payload: { step_handler: simple_handler })
      expect(s2[:results].size).to eq(2)
    end

    it "marks step as :failed when handler raises" do
      bad_handler = ->(step:, **) { raise "boom" }
      result = call_handler(:execute_next, state: planned_state,
        payload: { step_handler: bad_handler })
      expect(result[:plan].first.status).to eq(:failed)
      expect(result[:plan].first.result).to eq("boom")
    end

    it "marks step as :skipped when no handler is configured" do
      result = call_handler(:execute_next, state: planned_state, payload: {})
      expect(result[:plan].first.status).to eq(:skipped)
    end

    it "is a no-op when plan is complete" do
      state = planned_state.merge(current_step: 3)
      result = call_handler(:execute_next, state: state, payload: {})
      expect(result).to eq(state)
    end
  end

  # ── :run_to_completion ────────────────────────────────────────────────────

  describe "on :run_to_completion" do
    it "creates a plan and executes all steps" do
      planner = ->(goal:, context:) { %w[X Y Z] }
      result  = call_handler(:run_to_completion, payload: {
        goal:         "Full run",
        planner:      planner,
        step_handler: simple_handler
      })
      expect(result[:results].size).to eq(3)
      expect(result[:plan].map(&:status)).to all(eq(:done))
    end

    it "works without a planner (single-step goal)" do
      result = call_handler(:run_to_completion, payload: {
        goal:         "Single task",
        step_handler: simple_handler
      })
      expect(result[:results].size).to eq(1)
    end

    it "passes previous results to each step" do
      received_results = []
      handler = ->(step:, index:, context:, results:) do
        received_results << results.dup
        "done"
      end
      planner = ->(goal:, context:) { %w[A B] }
      call_handler(:run_to_completion, payload: {
        goal: "g", planner: planner, step_handler: handler
      })
      expect(received_results[0]).to be_empty
      expect(received_results[1].size).to eq(1)
    end
  end

  # ── :status ───────────────────────────────────────────────────────────────

  describe "on :status" do
    it "returns a PlanStatus struct" do
      result = call_handler(:status)
      expect(result).to be_a(described_class::PlanStatus)
    end

    it "reflects completed and failed counts" do
      planner = ->(goal:, context:) { %w[A B] }
      state   = call_handler(:plan, payload: { goal: "g", planner: planner })
      state   = call_handler(:execute_next, state: state,
        payload: { step_handler: simple_handler })
      state   = call_handler(:execute_next, state: state,
        payload: { step_handler: ->(step:, **) { raise "fail" } })
      status  = call_handler(:status, state: state)
      expect(status.completed).to eq(1)
      expect(status.failed).to eq(1)
    end
  end

  # ── :reset / :configure ───────────────────────────────────────────────────

  describe "on :reset" do
    it "clears plan, cursor, and results" do
      planner = ->(goal:, context:) { %w[A] }
      state   = call_handler(:run_to_completion, payload: {
        goal: "g", planner: planner, step_handler: simple_handler
      })
      result  = call_handler(:reset, state: state)
      expect(result[:plan]).to be_empty
      expect(result[:current_step]).to eq(0)
      expect(result[:results]).to be_empty
    end
  end

  describe "on :configure" do
    it "updates planner" do
      p      = ->(goal:, context:) { ["x"] }
      result = call_handler(:configure, payload: { planner: p })
      expect(result[:planner]).to equal(p)
    end

    it "updates step_handler" do
      h      = ->(step:, **) { "ok" }
      result = call_handler(:configure, payload: { step_handler: h })
      expect(result[:step_handler]).to equal(h)
    end
  end
end
