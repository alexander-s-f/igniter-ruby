# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::ChainAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  let(:upcase_step)  { ->(input:, **) { input.to_s.upcase } }
  let(:reverse_step) { ->(input:, **) { input.to_s.reverse } }
  let(:exclaim_step) { ->(input:, **) { "#{input}!" } }

  # ── :add_step ─────────────────────────────────────────────────────────────

  describe "on :add_step" do
    it "appends a step to the chain" do
      result = call_handler(:add_step,
        payload: { name: :upcase, callable: upcase_step })
      expect(result[:chain].size).to eq(1)
      expect(result[:chain].first[:name]).to eq("upcase")
    end

    it "builds chain incrementally" do
      s1 = call_handler(:add_step, payload: { name: :a, callable: upcase_step })
      s2 = call_handler(:add_step, state: s1, payload: { name: :b, callable: reverse_step })
      expect(s2[:chain].size).to eq(2)
    end
  end

  # ── :set_chain ────────────────────────────────────────────────────────────

  describe "on :set_chain" do
    it "replaces the entire chain" do
      s1 = call_handler(:add_step, payload: { name: :old, callable: upcase_step })
      result = call_handler(:set_chain, state: s1, payload: {
        steps: [{ name: :new, callable: reverse_step }]
      })
      expect(result[:chain].map { |s| s[:name] }).to eq(["new"])
    end
  end

  # ── :remove_step ──────────────────────────────────────────────────────────

  describe "on :remove_step" do
    it "removes a step by name" do
      state  = call_handler(:set_chain, payload: {
        steps: [{ name: :a, callable: upcase_step }, { name: :b, callable: reverse_step }]
      })
      result = call_handler(:remove_step, state: state, payload: { name: :a })
      expect(result[:chain].map { |s| s[:name] }).to eq(["b"])
    end
  end

  # ── :run ──────────────────────────────────────────────────────────────────

  describe "on :run — basic chaining" do
    let(:chain_state) do
      call_handler(:set_chain, payload: {
        steps: [
          { name: :upcase,  callable: upcase_step },
          { name: :reverse, callable: reverse_step },
          { name: :exclaim, callable: exclaim_step }
        ]
      })
    end

    it "pipes output through each step in order" do
      result = call_handler(:run, state: chain_state, payload: { input: "hello" })
      # "hello" → "HELLO" → "OLLEH" → "OLLEH!"
      expect(result[:results].last.output).to eq("OLLEH!")
    end

    it "records a StepResult for every step" do
      result = call_handler(:run, state: chain_state, payload: { input: "x" })
      expect(result[:results].size).to eq(3)
      expect(result[:results]).to all(be_a(described_class::StepResult))
    end

    it "records each step's input" do
      result = call_handler(:run, state: chain_state, payload: { input: "hello" })
      expect(result[:results][0].input).to eq("hello")
      expect(result[:results][1].input).to eq("HELLO")
    end

    it "marks successful steps as :ok" do
      result = call_handler(:run, state: chain_state, payload: { input: "a" })
      expect(result[:results].map(&:status)).to all(eq(:ok))
    end

    it "passes context to every step" do
      received = []
      ctx_step = ->(input:, context:, **) { received << context; input }
      state    = call_handler(:set_chain,
        payload: { steps: [{ name: :c, callable: ctx_step }] })
      call_handler(:run, state: state, payload: { input: "x", context: { env: :test } })
      expect(received.first).to eq({ env: :test })
    end
  end

  describe "on :run — error handling" do
    let(:boom_step) { ->(input:, **) { raise "explode" } }

    it "marks a failing step as :error" do
      state  = call_handler(:set_chain,
        payload: { steps: [{ name: :bad, callable: boom_step }] })
      result = call_handler(:run, state: state, payload: { input: "x" })
      expect(result[:results].first.status).to eq(:error)
      expect(result[:results].first.output).to eq("explode")
    end

    it "stops the chain on error by default" do
      state = call_handler(:set_chain, payload: {
        steps: [
          { name: :fail, callable: boom_step },
          { name: :ok,   callable: upcase_step }
        ]
      })
      result = call_handler(:run, state: state, payload: { input: "x" })
      expect(result[:results].size).to eq(1) # stopped after first failure
    end

    it "continues chain when stop_on_error: false" do
      state = call_handler(:set_chain, payload: {
        steps: [
          { name: :fail, callable: boom_step },
          { name: :ok,   callable: upcase_step }
        ]
      })
      result = call_handler(:run, state: state,
        payload: { input: "x", stop_on_error: false })
      expect(result[:results].size).to eq(2)
      expect(result[:results].last.status).to eq(:ok)
    end
  end

  describe "on :run — result access inside steps" do
    it "passes previous StepResults to subsequent steps" do
      received = []
      inspector = ->(input:, results:, **) { received << results.dup; input }
      state = call_handler(:set_chain, payload: {
        steps: [
          { name: :first,  callable: upcase_step },
          { name: :second, callable: inspector }
        ]
      })
      call_handler(:run, state: state, payload: { input: "hi" })
      expect(received.first.size).to eq(1)
      expect(received.first.first.name).to eq("first")
    end
  end

  # ── :results / :steps / :reset ────────────────────────────────────────────

  describe "on :results" do
    it "returns results from the last run" do
      state  = call_handler(:set_chain,
        payload: { steps: [{ name: :a, callable: upcase_step }] })
      state  = call_handler(:run, state: state, payload: { input: "x" })
      result = call_handler(:results, state: state)
      expect(result).to be_an(Array)
      expect(result.first).to be_a(described_class::StepResult)
    end
  end

  describe "on :steps" do
    it "returns registered step names" do
      state  = call_handler(:set_chain, payload: {
        steps: [{ name: :a, callable: upcase_step },
                { name: :b, callable: reverse_step }]
      })
      result = call_handler(:steps, state: state)
      expect(result).to eq(["a", "b"])
    end
  end

  describe "on :reset" do
    it "clears results while preserving the chain" do
      state  = call_handler(:set_chain,
        payload: { steps: [{ name: :a, callable: upcase_step }] })
      state  = call_handler(:run, state: state, payload: { input: "hi" })
      result = call_handler(:reset, state: state)
      expect(result[:results]).to be_empty
      expect(result[:chain].size).to eq(1)
    end
  end
end
