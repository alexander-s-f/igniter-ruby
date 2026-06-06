# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::ObserverAgent do
  let(:h) { ->(type, state, payload = {}) { described_class.handlers[type].call(state: state, payload: payload) } }

  def base_state
    {
      subjects: [], observations: [], anomalies: [],
      rules: [], checked_until: 0, max_observations: 500
    }
  end

  # ── :watch / :unwatch ──────────────────────────────────────────────────────
  describe "on :watch" do
    it "registers a subject" do
      result = h.call(:watch, base_state, subject: :payments)
      expect(result[:subjects]).to include(:payments)
    end

    it "coerces subject to symbol" do
      result = h.call(:watch, base_state, subject: "orders")
      expect(result[:subjects]).to include(:orders)
    end

    it "does not add duplicates" do
      state  = h.call(:watch, base_state, subject: :api)
      result = h.call(:watch, state, subject: :api)
      expect(result[:subjects].count(:api)).to eq(1)
    end
  end

  describe "on :unwatch" do
    it "removes the subject" do
      state  = h.call(:watch, base_state, subject: :svc)
      result = h.call(:unwatch, state, subject: :svc)
      expect(result[:subjects]).not_to include(:svc)
    end
  end

  # ── :observe ───────────────────────────────────────────────────────────────
  describe "on :observe" do
    it "records an Observation" do
      result = h.call(:observe, base_state, subject: :api, event: :request)
      expect(result[:observations].size).to eq(1)
      expect(result[:observations].first).to be_a(described_class::Observation)
    end

    it "stores subject and event" do
      result = h.call(:observe, base_state, subject: :db, event: :error)
      obs = result[:observations].first
      expect(obs.subject).to eq(:db)
      expect(obs.event).to eq(:error)
    end

    it "stores optional data" do
      result = h.call(:observe, base_state, subject: :x, event: :e, data: { code: 500 })
      expect(result[:observations].first.data).to eq({ code: 500 })
    end

    it "caps observations at max_observations" do
      state = base_state.merge(max_observations: 3)
      4.times { |i| state = h.call(:observe, state, subject: :x, event: :"e#{i}") }
      expect(state[:observations].size).to eq(3)
    end

    it "does NOT run rules (no anomalies created)" do
      error_rule = described_class::Rule.new(name: :errors, matcher: ->(o) { o.event == :error })
      state = base_state.merge(rules: [error_rule])
      result = h.call(:observe, state, subject: :api, event: :error)
      expect(result[:anomalies]).to be_empty
    end
  end

  # ── :add_rule / :remove_rule ───────────────────────────────────────────────
  describe "on :add_rule" do
    let(:matcher) { ->(_obs) { false } }

    it "adds a rule" do
      result = h.call(:add_rule, base_state, name: :my_rule, matcher: matcher)
      expect(result[:rules].map(&:name)).to include(:my_rule)
    end

    it "replaces an existing rule with the same name" do
      new_matcher = ->(_obs) { true }
      state  = h.call(:add_rule, base_state, name: :r, matcher: matcher)
      result = h.call(:add_rule, state,  name: :r, matcher: new_matcher)
      rules  = result[:rules].select { |r| r.name == :r }
      expect(rules.size).to eq(1)
      expect(rules.first.matcher).to eq(new_matcher)
    end
  end

  describe "on :remove_rule" do
    it "removes the named rule" do
      state  = h.call(:add_rule, base_state, name: :r, matcher: ->(_) { true })
      result = h.call(:remove_rule, state, name: :r)
      expect(result[:rules].map(&:name)).not_to include(:r)
    end
  end

  # ── :check ─────────────────────────────────────────────────────────────────
  describe "on :check" do
    let(:error_rule) do
      described_class::Rule.new(name: :errors, matcher: ->(o) { o.event == :error })
    end

    it "detects an anomaly when rule matches" do
      state  = base_state.merge(rules: [error_rule])
      state  = h.call(:observe, state, subject: :api, event: :error)
      result = h.call(:check, state)
      expect(result[:anomalies].size).to eq(1)
      expect(result[:anomalies].first.rule).to eq(:errors)
    end

    it "does not detect anomaly when rule does not match" do
      state  = base_state.merge(rules: [error_rule])
      state  = h.call(:observe, state, subject: :api, event: :ok)
      result = h.call(:check, state)
      expect(result[:anomalies]).to be_empty
    end

    it "advances checked_until cursor" do
      state  = base_state.merge(rules: [error_rule])
      state  = h.call(:observe, state, subject: :api, event: :ok)
      state  = h.call(:observe, state, subject: :api, event: :ok)
      result = h.call(:check, state)
      expect(result[:checked_until]).to eq(2)
    end

    it "does not re-check already checked observations" do
      state  = base_state.merge(rules: [error_rule])
      state  = h.call(:observe, state, subject: :api, event: :error)
      state  = h.call(:check, state) # first check — detects anomaly
      state  = h.call(:check, state) # second check — no new observations
      expect(state[:anomalies].size).to eq(1)
    end

    it "limits scan to :window newest observations when specified" do
      state = base_state.merge(rules: [error_rule])
      3.times { state = h.call(:observe, state, subject: :api, event: :error) }
      result = h.call(:check, state, window: 1)
      expect(result[:anomalies].size).to eq(1)
    end
  end

  # ── sync queries ────────────────────────────────────────────────────────────
  describe "on :observations" do
    it "returns all observations" do
      state  = h.call(:observe, base_state, subject: :x, event: :e)
      result = h.call(:observations, state)
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
    end

    it "filters by subject" do
      state = h.call(:observe, base_state, subject: :a, event: :e)
      state = h.call(:observe, state,  subject: :b, event: :e)
      result = h.call(:observations, state, subject: :a)
      expect(result.map(&:subject)).to all(eq(:a))
    end
  end

  describe "on :anomalies" do
    let(:any_rule) do
      described_class::Rule.new(name: :any, matcher: ->(_) { true })
    end

    it "returns all anomalies" do
      state  = base_state.merge(rules: [any_rule])
      state  = h.call(:observe, state, subject: :x, event: :e)
      state  = h.call(:check, state)
      expect(h.call(:anomalies, state)).to be_an(Array)
    end

    it "filters by subject" do
      state = base_state.merge(rules: [any_rule])
      state = h.call(:observe, state, subject: :svc_a, event: :e)
      state = h.call(:observe, state, subject: :svc_b, event: :e)
      state = h.call(:check, state)
      result = h.call(:anomalies, state, subject: :svc_a)
      expect(result.map(&:subject)).to all(eq(:svc_a))
    end
  end

  describe "on :summary" do
    it "returns a Summary struct" do
      result = h.call(:summary, base_state)
      expect(result).to be_a(described_class::Summary)
    end

    it "counts subjects, observations, anomalies, rules" do
      state  = h.call(:watch, base_state, subject: :x)
      state  = h.call(:observe, state, subject: :x, event: :e)
      result = h.call(:summary, state)
      expect(result.subjects).to eq(1)
      expect(result.observations).to eq(1)
      expect(result.anomalies).to eq(0)
      expect(result.rules).to eq(0)
    end
  end

  describe "on :clear_anomalies" do
    let(:any_rule) { described_class::Rule.new(name: :any, matcher: ->(_) { true }) }

    it "empties the anomaly list and resets cursor" do
      state  = base_state.merge(rules: [any_rule])
      state  = h.call(:observe, state, subject: :x, event: :e)
      state  = h.call(:check, state)
      result = h.call(:clear_anomalies, state)
      expect(result[:anomalies]).to be_empty
      expect(result[:checked_until]).to eq(0)
    end
  end

  # ── :configure ─────────────────────────────────────────────────────────────
  describe "on :configure" do
    it "updates max_observations" do
      result = h.call(:configure, base_state, max_observations: 1000)
      expect(result[:max_observations]).to eq(1000)
    end
  end
end
