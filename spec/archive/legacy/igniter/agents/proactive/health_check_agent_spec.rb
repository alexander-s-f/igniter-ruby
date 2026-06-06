# frozen_string_literal: true

require "spec_helper"
require "igniter/agents/proactive/health_check_agent"

RSpec.describe Igniter::Agents::HealthCheckAgent do
  let(:h) { ->(klass, type, state, payload = {}) { klass.handlers[type].call(state: state, payload: payload) } }

  def build_agent(&dsl)
    klass = Class.new(described_class)
    klass.class_eval(&dsl) if dsl
    klass
  end

  def base_state(extra = {})
    {
      active: true, context: {}, scan_count: 0,
      last_scan_at: nil, trigger_history: [],
      health: {}, transitions: []
    }.merge(extra)
  end

  # ── .check ─────────────────────────────────────────────────────────────────
  describe ".check" do
    it "registers a watcher" do
      agent = build_agent { check :db, poll: -> { true } }
      expect(agent.watchers).to have_key(:db)
    end

    it "registered watcher returns :healthy when poll is truthy" do
      agent = build_agent { check :db, poll: -> { true } }
      expect(agent.watchers[:db].call).to eq(:healthy)
    end

    it "registered watcher returns :unhealthy when poll returns falsy" do
      agent = build_agent { check :db, poll: -> { nil } }
      expect(agent.watchers[:db].call).to eq(:unhealthy)
    end

    it "registered watcher returns :unhealthy when poll raises" do
      agent = build_agent { check :db, poll: -> { raise "connection refused" } }
      expect(agent.watchers[:db].call).to eq(:unhealthy)
    end

    it "registers a trigger for the service" do
      agent = build_agent { check :db, poll: -> { true } }
      expect(agent.proactive_triggers).to have_key(:health_db)
    end
  end

  # ── :_scan — unhealthy detection ──────────────────────────────────────────
  # poll: -> { false } makes the watcher return :unhealthy (false is falsy)
  describe "on :_scan — unhealthy service" do
    let(:agent) { build_agent { check :db, poll: -> { false } } }

    it "updates health status to :unhealthy" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:health][:db]).to eq(:unhealthy)
    end

    it "records a transition when status changes from unknown to :unhealthy" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:transitions].size).to eq(1)
      t = result[:transitions].first
      expect(t.service).to eq(:db)
      expect(t.from).to eq(:unknown)
      expect(t.to).to eq(:unhealthy)
    end

    it "does NOT add duplicate transition when status remains :unhealthy" do
      result = h.call(agent, :_scan, base_state(health: { db: :unhealthy }))
      expect(result[:transitions]).to be_empty
    end
  end

  # ── :_scan — healthy service ───────────────────────────────────────────────
  describe "on :_scan — healthy service" do
    let(:agent) { build_agent { check :db, poll: -> { true } } }

    it "does not record a transition when healthy" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:transitions]).to be_empty
    end
  end

  # ── multiple services ──────────────────────────────────────────────────────
  describe "multiple services" do
    let(:agent) do
      build_agent do
        check :db,    poll: -> { true }
        check :redis, poll: -> { nil }
      end
    end

    it "tracks health for each service independently" do
      result = h.call(agent, :_scan, base_state)
      expect(result[:health][:redis]).to eq(:unhealthy)
    end

    it "only records transitions for unhealthy services" do
      result   = h.call(agent, :_scan, base_state)
      services = result[:transitions].map(&:service)
      expect(services).to contain_exactly(:redis)
    end
  end

  # ── :health ────────────────────────────────────────────────────────────────
  describe "on :health" do
    it "returns the health status Hash" do
      agent  = build_agent
      state  = base_state(health: { db: :healthy })
      result = h.call(agent, :health, state)
      expect(result).to eq({ db: :healthy })
    end
  end

  # ── :all_healthy ──────────────────────────────────────────────────────────
  describe "on :all_healthy" do
    it "returns true when all services are healthy" do
      state = base_state(health: { db: :healthy, redis: :healthy })
      expect(h.call(build_agent, :all_healthy, state)).to be true
    end

    it "returns false when any service is unhealthy" do
      state = base_state(health: { db: :healthy, redis: :unhealthy })
      expect(h.call(build_agent, :all_healthy, state)).to be false
    end

    it "returns true for empty health map" do
      expect(h.call(build_agent, :all_healthy, base_state)).to be true
    end
  end

  # ── :transitions ──────────────────────────────────────────────────────────
  describe "on :transitions" do
    it "returns the transition history" do
      agent = build_agent
      state = base_state(transitions: [
        described_class::Transition.new(
          service: :db, from: :unknown, to: :unhealthy, occurred_at: Time.now
        )
      ])
      result = h.call(agent, :transitions, state)
      expect(result.first.service).to eq(:db)
    end
  end

  # ── :reset ─────────────────────────────────────────────────────────────────
  describe "on :reset" do
    it "clears health and transitions" do
      state  = base_state(health: { db: :unhealthy }, transitions: [:x])
      result = h.call(build_agent, :reset, state)
      expect(result[:health]).to be_empty
      expect(result[:transitions]).to be_empty
    end
  end

  # ── transition history cap ─────────────────────────────────────────────────
  describe "transition history cap" do
    it "keeps at most 100 transitions" do
      agent = build_agent { check :db, poll: -> { nil } }
      transitions = Array.new(100) {
        described_class::Transition.new(service: :db, from: :unknown, to: :unhealthy, occurred_at: Time.now)
      }
      state  = base_state(transitions: transitions)
      result = h.call(agent, :_scan, state)
      expect(result[:transitions].size).to eq(100)
    end
  end

  # ── inherited proactive behaviour ─────────────────────────────────────────
  describe "inherited proactive behaviour" do
    let(:agent) { build_agent }

    it "has :pause and :resume handlers" do
      expect(agent.handlers).to have_key(:pause)
      expect(agent.handlers).to have_key(:resume)
    end

    it "scan does nothing when paused" do
      state  = base_state(active: false, context: { db: :unhealthy })
      result = h.call(agent, :_scan, state)
      expect(result[:transitions]).to be_empty
    end
  end
end
