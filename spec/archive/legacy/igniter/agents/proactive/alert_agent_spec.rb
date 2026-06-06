# frozen_string_literal: true

require "spec_helper"
require "igniter/agents/proactive/alert_agent"

RSpec.describe Igniter::Agents::AlertAgent do
  let(:h) { ->(klass, type, state, payload = {}) { klass.handlers[type].call(state: state, payload: payload) } }

  # Build an isolated subclass for each test group.
  def build_agent(&dsl)
    klass = Class.new(described_class)
    klass.class_eval(&dsl) if dsl
    klass
  end

  def base_state(extra = {})
    {
      active: true, context: {}, scan_count: 0,
      last_scan_at: nil, trigger_history: [],
      alerts: [], silenced: false
    }.merge(extra)
  end

  # ── .monitor ───────────────────────────────────────────────────────────────
  describe ".monitor" do
    it "registers a watcher" do
      agent = build_agent { monitor :latency, source: -> { 100 } }
      expect(agent.watchers).to have_key(:latency)
    end

    it "watcher returns the poll result" do
      agent = build_agent { monitor :rps, source: -> { 500 } }
      expect(agent.watchers[:rps].call).to eq(500)
    end
  end

  # ── .threshold ─────────────────────────────────────────────────────────────
  describe ".threshold" do
    it "registers a trigger for the metric" do
      agent = build_agent { threshold :cpu, above: 0.9 }
      expect(agent.proactive_triggers).to have_key(:threshold_cpu)
    end

    it "registers both above and below in the same call" do
      agent = build_agent do
        threshold :latency, above: 500
        threshold :throughput, below: 100
      end
      expect(agent.proactive_triggers.keys).to include(:threshold_latency, :threshold_throughput)
    end
  end

  # ── Threshold trigger — above ──────────────────────────────────────────────
  # The watcher source controls what value is read during _scan.
  describe "threshold breach :above" do
    it "fires when value exceeds threshold" do
      agent = build_agent do
        monitor :cpu, source: -> { 0.95 }
        threshold :cpu, above: 0.8
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts].size).to eq(1)
      alert = result[:alerts].first
      expect(alert.metric).to eq(:cpu)
      expect(alert.kind).to eq(:above)
      expect(alert.threshold).to eq(0.8)
    end

    it "does not fire when value is within threshold" do
      agent = build_agent do
        monitor :cpu, source: -> { 0.5 }
        threshold :cpu, above: 0.8
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts]).to be_empty
    end

    it "records the breach value" do
      agent = build_agent do
        monitor :cpu, source: -> { 0.99 }
        threshold :cpu, above: 0.8
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts].first.value).to eq(0.99)
    end
  end

  # ── Threshold trigger — below ──────────────────────────────────────────────
  describe "threshold breach :below" do
    it "fires when value drops below threshold" do
      agent = build_agent do
        monitor :throughput, source: -> { 50 }
        threshold :throughput, below: 100
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts].first.kind).to eq(:below)
    end

    it "does not fire when value is above threshold" do
      agent = build_agent do
        monitor :throughput, source: -> { 200 }
        threshold :throughput, below: 100
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts]).to be_empty
    end
  end

  # ── nil context value ──────────────────────────────────────────────────────
  describe "nil context value" do
    it "does not fire when watcher returns nil" do
      agent = build_agent do
        monitor :cpu, source: -> { nil }
        threshold :cpu, above: 0.5
      end
      result = h.call(agent, :_scan, base_state)
      expect(result[:alerts]).to be_empty
    end
  end

  # ── silenced ───────────────────────────────────────────────────────────────
  describe "on :silence / :unsilence" do
    let(:agent) do
      build_agent do
        monitor :cpu, source: -> { 0.99 }  # always above threshold
        threshold :cpu, above: 0.5
      end
    end

    it "suppresses alert creation when silenced" do
      result = h.call(agent, :_scan, base_state(silenced: true))
      expect(result[:alerts]).to be_empty
    end

    it ":silence sets silenced true" do
      result = h.call(agent, :silence, base_state)
      expect(result[:silenced]).to be true
    end

    it ":unsilence sets silenced false" do
      result = h.call(agent, :unsilence, base_state(silenced: true))
      expect(result[:silenced]).to be false
    end
  end

  # ── :alerts / :clear_alerts ────────────────────────────────────────────────
  describe "on :alerts" do
    it "returns an Array" do
      expect(h.call(build_agent, :alerts, base_state)).to eq([])
    end

    it "returns recorded alerts" do
      agent  = build_agent do
        monitor :cpu, source: -> { 0.9 }
        threshold :cpu, above: 0.5
      end
      state  = h.call(agent, :_scan, base_state)
      result = h.call(agent, :alerts, state)
      expect(result.first).to be_a(described_class::AlertRecord)
    end
  end

  describe "on :clear_alerts" do
    it "empties the alert list" do
      agent  = build_agent do
        monitor :cpu, source: -> { 0.9 }
        threshold :cpu, above: 0.5
      end
      state  = h.call(agent, :_scan, base_state)
      result = h.call(agent, :clear_alerts, state)
      expect(result[:alerts]).to be_empty
    end
  end

  # ── Inherited ProactiveAgent behaviour ────────────────────────────────────
  describe "inherited proactive behaviour" do
    let(:agent) { build_agent }

    it "has :_scan, :pause, :resume, :status handlers" do
      %i[_scan pause resume status].each do |type|
        expect(agent.handlers).to have_key(type)
      end
    end

    it "scan_count increments on :_scan" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:scan_count]).to eq(1)
    end
  end

  # ── Alert caps at 200 ─────────────────────────────────────────────────────
  describe "alert history cap" do
    it "keeps at most 200 alerts" do
      agent = build_agent do
        monitor :v, source: -> { 1 }
        threshold :v, above: -1
      end
      state = base_state(alerts: Array.new(200) {
        described_class::AlertRecord.new(
          metric: :v, value: 1, kind: :above, threshold: -1, fired_at: Time.now
        )
      })
      result = h.call(agent, :_scan, state)
      expect(result[:alerts].size).to eq(200)
      expect(result[:alerts].last.value).to eq(1)
    end
  end
end
