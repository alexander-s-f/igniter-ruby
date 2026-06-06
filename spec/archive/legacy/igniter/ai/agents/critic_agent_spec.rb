# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::CriticAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  # ── Rule-based evaluation ────────────────────────────────────────────────

  describe "on :evaluate — rule-based" do
    it "scores empty output as 0 (failed)" do
      result = call_handler(:evaluate, payload: { output: "" })
      ev     = result[:evaluations].last
      expect(ev.score).to eq(0.0)
      expect(ev.passed).to be false
    end

    it "scores very short output below passing threshold" do
      result = call_handler(:evaluate, payload: { output: "Hi" })
      ev     = result[:evaluations].last
      expect(ev.score).to be < 7.0
      expect(ev.passed).to be false
    end

    it "scores a 200+ char output above default threshold" do
      long_output = "A" * 250
      result = call_handler(:evaluate, payload: { output: long_output })
      ev     = result[:evaluations].last
      expect(ev.passed).to be true
    end

    it "appends evaluation to state" do
      state1 = call_handler(:evaluate, payload: { output: "" })
      state2 = call_handler(:evaluate, state: state1, payload: { output: "B" * 300 })
      expect(state2[:evaluations].size).to eq(2)
    end

    it "stores the criteria in the evaluation" do
      result = call_handler(:evaluate, payload: { output: "x", criteria: "accuracy" })
      expect(result[:evaluations].last.criteria).to eq("accuracy")
    end
  end

  # ── LLM-assisted evaluation ──────────────────────────────────────────────

  describe "on :evaluate — LLM evaluator" do
    let(:good_evaluator) { ->(output:, criteria:) { { score: 9.0, feedback: "Excellent" } } }
    let(:bad_evaluator)  { ->(output:, criteria:) { { score: 2.0, feedback: "Too vague" } } }

    it "uses evaluator score" do
      result = call_handler(:evaluate, payload: { output: "anything", evaluator: good_evaluator })
      expect(result[:evaluations].last.score).to eq(9.0)
    end

    it "marks as passed when score >= threshold" do
      result = call_handler(:evaluate, payload: { output: "x", evaluator: good_evaluator })
      expect(result[:evaluations].last.passed).to be true
    end

    it "marks as failed when score < threshold" do
      result = call_handler(:evaluate,
        payload: { output: "x", evaluator: bad_evaluator, threshold: 7.0 })
      expect(result[:evaluations].last.passed).to be false
    end

    it "accepts a string response and extracts the first number as score" do
      str_evaluator = ->(output:, criteria:) { "Score: 8 — looks good" }
      result = call_handler(:evaluate, payload: { output: "x", evaluator: str_evaluator })
      expect(result[:evaluations].last.score).to eq(8.0)
    end

    it "scores 0 and records the error when evaluator raises" do
      raising = ->(output:, criteria:) { raise "provider down" }
      result  = call_handler(:evaluate, payload: { output: "x", evaluator: raising })
      ev      = result[:evaluations].last
      expect(ev.score).to eq(0.0)
      expect(ev.feedback).to include("provider down")
    end

    it "allows per-call threshold override" do
      result = call_handler(:evaluate,
        payload: { output: "x", evaluator: good_evaluator, threshold: 9.5 })
      expect(result[:evaluations].last.passed).to be false
    end
  end

  # ── evaluate_and_retry ───────────────────────────────────────────────────

  describe "on :evaluate_and_retry" do
    it "stops after the first passing evaluation" do
      attempt    = 0
      evaluator  = ->(output:, criteria:) { { score: attempt.positive? ? 9.0 : 2.0, feedback: "" } }
      generator  = -> { attempt += 1; "improved output #{"x" * 300}" }

      result = call_handler(:evaluate_and_retry, payload: {
        output:      "short",
        evaluator:   evaluator,
        generator:   generator,
        max_retries: 5
      })
      expect(attempt).to eq(1)
      expect(result[:evaluations].last.passed).to be true
    end

    it "exhausts retries when output never passes" do
      evaluator = ->(output:, criteria:) { { score: 1.0, feedback: "bad" } }
      calls     = 0
      generator = -> { calls += 1; "still bad" }

      call_handler(:evaluate_and_retry, payload: {
        output:      "initial",
        evaluator:   evaluator,
        generator:   generator,
        max_retries: 2
      })
      expect(calls).to eq(2)
    end

    it "appends all evaluations including intermediate failures" do
      evaluator = ->(output:, criteria:) { { score: 1.0, feedback: "" } }
      result    = call_handler(:evaluate_and_retry, payload: {
        output:      "x",
        evaluator:   evaluator,
        generator:   -> { "y" },
        max_retries: 2
      })
      expect(result[:evaluations].size).to eq(3) # initial + 2 retries
    end
  end

  # ── configure / queries ───────────────────────────────────────────────────

  describe "on :configure" do
    it "updates threshold" do
      result = call_handler(:configure, payload: { threshold: 9.0 })
      expect(result[:threshold]).to eq(9.0)
    end

    it "updates evaluator" do
      ev     = ->(output:, criteria:) { { score: 10.0, feedback: "" } }
      result = call_handler(:configure, payload: { evaluator: ev })
      expect(result[:evaluator]).to equal(ev)
    end
  end

  describe "on :last_evaluation" do
    it "returns nil when no evaluations exist" do
      expect(call_handler(:last_evaluation)).to be_nil
    end

    it "returns the most recent Evaluation struct" do
      state  = call_handler(:evaluate, payload: { output: "x" })
      result = call_handler(:last_evaluation, state: state)
      expect(result).to be_a(described_class::Evaluation)
    end
  end

  describe "on :evaluations" do
    it "returns an Array" do
      expect(call_handler(:evaluations)).to be_an(Array)
    end
  end

  describe "on :clear" do
    it "empties the evaluations list" do
      state  = call_handler(:evaluate, payload: { output: "x" })
      result = call_handler(:clear, state: state)
      expect(result[:evaluations]).to be_empty
    end
  end
end
