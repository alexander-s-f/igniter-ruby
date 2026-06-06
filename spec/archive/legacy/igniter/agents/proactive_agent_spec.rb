# frozen_string_literal: true

require "spec_helper"
require "igniter/agents/proactive_agent"

RSpec.describe Igniter::Agents::ProactiveAgent do
  # Build a minimal concrete subclass for each example group to keep state isolated.
  def build_agent(scan_interval: nil, &dsl)
    klass = Class.new(described_class)
    klass.proactive_initial_state
    klass.class_eval(&dsl) if dsl
    klass.scan_interval(scan_interval) if scan_interval
    klass
  end

  let(:h) { ->(klass, type, state, payload = {}) { klass.handlers[type].call(state: state, payload: payload) } }

  def base_state(extra = {})
    {
      active: true, context: {}, scan_count: 0,
      last_scan_at: nil, trigger_history: []
    }.merge(extra)
  end

  # ── Injection sanity ───────────────────────────────────────────────────────
  describe "handler injection" do
    let(:agent) { build_agent }

    it "injects :_scan handler" do
      expect(agent.handlers).to have_key(:_scan)
    end

    it "injects :pause / :resume handlers" do
      expect(agent.handlers).to have_key(:pause)
      expect(agent.handlers).to have_key(:resume)
    end

    it "injects :status handler" do
      expect(agent.handlers).to have_key(:status)
    end

    it "injects :context and :trigger_history handlers" do
      expect(agent.handlers).to have_key(:context)
      expect(agent.handlers).to have_key(:trigger_history)
    end
  end

  # ── DSL ────────────────────────────────────────────────────────────────────
  describe ".intent" do
    it "stores a human-readable intent string" do
      agent = build_agent { intent "Monitor errors" }
      expect(agent.intent).to eq("Monitor errors")
    end

    it "returns nil when not set" do
      expect(build_agent.intent).to be_nil
    end
  end

  describe ".watch" do
    it "registers a watcher by name" do
      agent = build_agent { watch :cpu, poll: -> { 0.42 } }
      expect(agent.watchers).to have_key(:cpu)
    end
  end

  describe ".trigger" do
    it "registers a trigger by name" do
      agent = build_agent do
        trigger :high_cpu,
          condition: ->(ctx) { ctx[:cpu].to_f > 0.9 },
          action:    ->(state:, context:) { state }
      end
      expect(agent.proactive_triggers).to have_key(:high_cpu)
    end
  end

  describe ".proactive_initial_state" do
    it "includes the required ProactiveAgent keys" do
      agent = build_agent
      state = agent.default_state
      expect(state).to include(:active, :context, :scan_count, :trigger_history)
    end

    it "merges extra keys" do
      agent = Class.new(described_class)
      agent.proactive_initial_state(queue: [])
      expect(agent.default_state[:queue]).to eq([])
    end
  end

  # ── :_scan — watcher execution ─────────────────────────────────────────────
  describe "on :_scan — watchers" do
    it "calls each watcher and stores readings in context" do
      agent = build_agent { watch :cpu, poll: -> { 0.5 } }
      result = h.call(agent, :_scan, base_state)
      expect(result[:context][:cpu]).to eq(0.5)
    end

    it "records nil for a watcher that raises" do
      agent = build_agent { watch :bad, poll: -> { raise "boom" } }
      result = h.call(agent, :_scan, base_state)
      expect(result[:context][:bad]).to be_nil
    end

    it "increments scan_count" do
      agent  = build_agent
      result = h.call(agent, :_scan, base_state)
      expect(result[:scan_count]).to eq(1)
    end

    it "sets last_scan_at" do
      agent  = build_agent
      result = h.call(agent, :_scan, base_state)
      expect(result[:last_scan_at]).to be_a(Time)
    end
  end

  # ── :_scan — trigger evaluation ───────────────────────────────────────────
  describe "on :_scan — triggers" do
    let(:agent) do
      build_agent do
        watch :value, poll: -> { 10 }
        trigger :high_value,
          condition: ->(ctx) { ctx[:value] > 5 },
          action:    ->(state:, context:) { state.merge(custom: "fired") }
      end
    end

    it "fires the action when condition is truthy" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:custom]).to eq("fired")
    end

    it "appends a FiredTrigger record to trigger_history" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:trigger_history].size).to eq(1)
      expect(result[:trigger_history].first.name).to eq(:high_value)
    end

    it "does not fire when condition is falsy" do
      agent2 = build_agent do
        watch :value, poll: -> { 1 }
        trigger :high_value,
          condition: ->(ctx) { ctx[:value] > 5 },
          action:    ->(state:, context:) { state.merge(custom: "fired") }
      end
      result = h.call(agent2, :_scan, base_state)
      expect(result[:custom]).to be_nil
      expect(result[:trigger_history]).to be_empty
    end

    it "keeps at most 100 trigger history entries" do
      agent3 = build_agent do
        watch :v, poll: -> { 1 }
        trigger :t, condition: ->(_) { true }, action: ->(state:, **) { state }
      end
      # pre-fill with 100 fired triggers
      filled = base_state(trigger_history: Array.new(100) {
        described_class::FiredTrigger.new(name: :old, fired_at: Time.now, context: {})
      })
      result = h.call(agent3, :_scan, filled)
      expect(result[:trigger_history].size).to eq(100)
      expect(result[:trigger_history].last.name).to eq(:t)
    end
  end

  # ── :_scan — paused ────────────────────────────────────────────────────────
  describe "on :_scan — when paused" do
    it "skips watcher execution and trigger evaluation" do
      agent = build_agent do
        watch :v, poll: -> { 99 }
        trigger :t, condition: ->(_) { true }, action: ->(state:, **) { state.merge(fired: true) }
      end
      result = h.call(agent, :_scan, base_state(active: false))
      expect(result[:context]).to be_empty
      expect(result[:fired]).to be_nil
    end
  end

  # ── :pause / :resume ───────────────────────────────────────────────────────
  describe "on :pause" do
    it "sets active to false" do
      agent  = build_agent
      result = h.call(agent, :pause, base_state)
      expect(result[:active]).to be false
    end
  end

  describe "on :resume" do
    it "sets active to true" do
      agent  = build_agent
      result = h.call(agent, :resume, base_state(active: false))
      expect(result[:active]).to be true
    end
  end

  # ── :status ────────────────────────────────────────────────────────────────
  describe "on :status" do
    it "returns a Status struct" do
      agent  = build_agent { intent "Test agent" }
      result = h.call(agent, :status, base_state)
      expect(result).to be_a(described_class::Status)
    end

    it "reflects scan_count and active flag" do
      agent  = build_agent
      state  = h.call(agent, :_scan, base_state)
      status = h.call(agent, :status, state)
      expect(status.scan_count).to eq(1)
      expect(status.active).to be true
    end

    it "lists registered watcher and trigger names" do
      agent = build_agent do
        watch :cpu, poll: -> { 0 }
        trigger :t, condition: ->(_) { false }, action: ->(state:, **) { state }
      end
      status = h.call(agent, :status, base_state)
      expect(status.watchers).to include(:cpu)
      expect(status.triggers).to include(:t)
    end
  end

  # ── :context ───────────────────────────────────────────────────────────────
  describe "on :context" do
    it "returns the last context snapshot" do
      agent  = build_agent { watch :v, poll: -> { 7 } }
      state  = h.call(agent, :_scan, base_state)
      result = h.call(agent, :context, state)
      expect(result[:v]).to eq(7)
    end
  end

  # ── :trigger_history ───────────────────────────────────────────────────────
  describe "on :trigger_history" do
    it "returns an Array" do
      expect(h.call(build_agent, :trigger_history, base_state)).to eq([])
    end
  end

  # ── scan_interval / timer registration ────────────────────────────────────
  describe ".scan_interval" do
    it "registers a timer with the given interval" do
      agent = build_agent(scan_interval: 5.0)
      expect(agent.timers.any? { |t| t[:interval] == 5.0 }).to be true
    end

    it "timer delegates to :_scan handler" do
      agent  = build_agent(scan_interval: 1.0) { watch :v, poll: -> { 42 } }
      timer  = agent.timers.find { |t| t[:name] == :_scan }
      result = timer[:handler].call(state: base_state)
      expect(result[:context][:v]).to eq(42)
    end
  end

  # ── Multiple watchers & triggers ──────────────────────────────────────────
  describe "multiple watchers and triggers" do
    it "evaluates all triggers in a single scan" do
      agent = build_agent do
        watch :a, poll: -> { 10 }
        watch :b, poll: -> { 20 }
        trigger :ta, condition: ->(ctx) { ctx[:a] > 5 }, action: ->(state:, **) { state.merge(ta: true) }
        trigger :tb, condition: ->(ctx) { ctx[:b] > 15 }, action: ->(state:, **) { state.merge(tb: true) }
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:ta]).to be true
      expect(result[:tb]).to be true
      expect(result[:trigger_history].size).to eq(2)
    end
  end
end
