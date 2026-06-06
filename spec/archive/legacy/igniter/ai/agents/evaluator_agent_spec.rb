# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::EvaluatorAgent do
  let(:h) { ->(type, state, payload = {}) { described_class.handlers[type].call(state: state, payload: payload) } }

  def base_state
    { subjects: {}, evaluations: [], weights: {} }
  end

  # ── :record_metric ─────────────────────────────────────────────────────────
  describe "on :record_metric" do
    it "creates a subject entry on first metric" do
      result = h.call(:record_metric, base_state, subject: :api, name: :latency, value: 42)
      expect(result[:subjects]["api"]).not_to be_nil
    end

    it "stores a MetricRecord with correct values" do
      result = h.call(:record_metric, base_state, subject: :api, name: :latency, value: 42)
      m = result[:subjects]["api"][:metrics].first
      expect(m.name).to eq("latency")
      expect(m.value).to eq(42.0)
    end

    it "accumulates multiple metrics" do
      state  = h.call(:record_metric, base_state, subject: :api, name: :latency, value: 100)
      result = h.call(:record_metric, state, subject: :api, name: :latency, value: 200)
      expect(result[:subjects]["api"][:metrics].size).to eq(2)
    end

    it "caps metrics per subject at 200" do
      state = base_state
      201.times { |i| state = h.call(:record_metric, state, subject: :x, name: :v, value: i) }
      expect(state[:subjects]["x"][:metrics].size).to eq(200)
    end
  end

  # ── :set_baseline ──────────────────────────────────────────────────────────
  describe "on :set_baseline" do
    it "stores the baseline for a subject" do
      result = h.call(:set_baseline, base_state, subject: :api, baseline: 1000)
      expect(result[:subjects]["api"][:baseline]).to eq(1000.0)
    end
  end

  # ── :set_weights ───────────────────────────────────────────────────────────
  describe "on :set_weights" do
    it "stores per-subject weights" do
      result = h.call(:set_weights, base_state, subject: :api, weights: { latency: 2.0 })
      expect(result[:subjects]["api"][:weights]["latency"]).to eq(2.0)
    end
  end

  # ── :evaluate ──────────────────────────────────────────────────────────────
  describe "on :evaluate" do
    it "appends an Evaluation" do
      state  = h.call(:record_metric, base_state, subject: :svc, name: :score, value: 90)
      result = h.call(:evaluate, state, subject: :svc)
      expect(result[:evaluations].size).to eq(1)
      expect(result[:evaluations].first).to be_a(described_class::Evaluation)
    end

    it "returns state unchanged when subject has no metrics" do
      result = h.call(:evaluate, base_state, subject: :missing)
      expect(result[:evaluations]).to be_empty
    end

    it "normalises score against baseline" do
      state = h.call(:record_metric, base_state, subject: :svc, name: :throughput, value: 750)
      state = h.call(:set_baseline,  state,       subject: :svc, baseline: 1000)
      result = h.call(:evaluate, state, subject: :svc)
      expect(result[:evaluations].last.score).to be_within(0.1).of(75.0)
    end

    it "assigns grade A for high score" do
      state = h.call(:record_metric, base_state, subject: :svc, name: :s, value: 950)
      state = h.call(:set_baseline,  state, subject: :svc, baseline: 1000)
      result = h.call(:evaluate, state, subject: :svc)
      expect(result[:evaluations].last.grade).to eq("A")
    end

    it "assigns grade D for low score" do
      state = h.call(:record_metric, base_state, subject: :svc, name: :s, value: 100)
      state = h.call(:set_baseline,  state, subject: :svc, baseline: 1000)
      result = h.call(:evaluate, state, subject: :svc)
      expect(result[:evaluations].last.grade).to eq("D")
    end

    it "applies global weights from state" do
      state = base_state.merge(weights: { "quality" => 3.0 })
      state = h.call(:record_metric, state, subject: :svc, name: :quality, value: 80)
      state = h.call(:record_metric, state, subject: :svc, name: :speed,   value: 20)
      result = h.call(:evaluate, state, subject: :svc)
      # quality contributes 3× more — score should lean toward 80
      expect(result[:evaluations].last.score).to be > 50
    end

    it "lists metric names in the evaluation" do
      state  = h.call(:record_metric, base_state, subject: :x, name: :rps, value: 100)
      result = h.call(:evaluate, state, subject: :x)
      expect(result[:evaluations].last.metrics).to include("rps")
    end
  end

  # ── :compare ───────────────────────────────────────────────────────────────
  describe "on :compare" do
    def setup_two_subjects
      state = base_state
      state = h.call(:record_metric, state, subject: :fast, name: :score, value: 900)
      state = h.call(:set_baseline,  state, subject: :fast, baseline: 1000)
      state = h.call(:record_metric, state, subject: :slow, name: :score, value: 600)
      state = h.call(:set_baseline,  state, subject: :slow, baseline: 1000)
      state = h.call(:evaluate, state, subject: :fast)
      h.call(:evaluate, state, subject: :slow)
    end

    it "returns a Comparison struct" do
      state = setup_two_subjects
      result = h.call(:compare, state, a: :fast, b: :slow)
      expect(result).to be_a(described_class::Comparison)
    end

    it "identifies the winner" do
      state  = setup_two_subjects
      result = h.call(:compare, state, a: :fast, b: :slow)
      expect(result.winner).to eq("fast")
    end

    it "reports delta between scores" do
      state  = setup_two_subjects
      result = h.call(:compare, state, a: :fast, b: :slow)
      expect(result.delta).to be_within(0.1).of(30.0)
    end

    it "returns nil when a subject has not been evaluated yet" do
      result = h.call(:compare, base_state, a: :x, b: :y)
      expect(result).to be_nil
    end

    it "reports :tie when scores are equal" do
      state = base_state
      %i[x y].each do |s|
        state = h.call(:record_metric, state, subject: s, name: :v, value: 500)
        state = h.call(:set_baseline,  state, subject: s, baseline: 1000)
        state = h.call(:evaluate,      state, subject: s)
      end
      result = h.call(:compare, state, a: :x, b: :y)
      expect(result.winner).to eq(:tie)
    end
  end

  # ── sync queries ────────────────────────────────────────────────────────────
  describe "on :evaluations" do
    it "returns all evaluations" do
      state  = h.call(:record_metric, base_state, subject: :s, name: :v, value: 1)
      state  = h.call(:evaluate, state, subject: :s)
      expect(h.call(:evaluations, state)).to be_an(Array)
    end

    it "filters by subject" do
      state = base_state
      %i[a b].each do |s|
        state = h.call(:record_metric, state, subject: s, name: :v, value: 1)
        state = h.call(:evaluate, state, subject: s)
      end
      result = h.call(:evaluations, state, subject: :a)
      expect(result.map(&:subject)).to all(eq("a"))
    end
  end

  describe "on :subjects" do
    it "lists registered subject names" do
      state  = h.call(:record_metric, base_state, subject: :svc, name: :v, value: 1)
      result = h.call(:subjects, state)
      expect(result).to include("svc")
    end
  end

  # ── :configure ─────────────────────────────────────────────────────────────
  describe "on :configure" do
    it "sets global weights" do
      result = h.call(:configure, base_state, weights: { "latency" => 2.0 })
      expect(result[:weights]["latency"]).to eq(2.0)
    end
  end

  # ── :reset ─────────────────────────────────────────────────────────────────
  describe "on :reset" do
    it "clears subjects and evaluations" do
      state  = h.call(:record_metric, base_state, subject: :x, name: :v, value: 1)
      state  = h.call(:evaluate, state, subject: :x)
      result = h.call(:reset, state)
      expect(result[:subjects]).to be_empty
      expect(result[:evaluations]).to be_empty
    end
  end
end
