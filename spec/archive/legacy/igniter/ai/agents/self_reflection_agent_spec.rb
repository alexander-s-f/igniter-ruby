# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::SelfReflectionAgent do
  let(:h) { ->(type, state, payload = {}) { described_class.handlers[type].call(state: state, payload: payload) } }

  def base_state
    { episodes: [], reflections: [], patches: [], llm: nil, window: 50, patches_applied: 0 }
  end

  # ── :record_episode ────────────────────────────────────────────────────────
  describe "on :record_episode" do
    it "appends an Episode to state" do
      result = h.call(:record_episode, base_state, action: :pay, outcome: :success)
      expect(result[:episodes].size).to eq(1)
      expect(result[:episodes].first).to be_a(described_class::Episode)
    end

    it "records action and outcome" do
      result = h.call(:record_episode, base_state, action: :charge, outcome: :failure)
      ep = result[:episodes].first
      expect(ep.action).to eq(:charge)
      expect(ep.outcome).to eq(:failure)
    end

    it "stores optional details" do
      result = h.call(:record_episode, base_state, action: :x, outcome: :success, details: { ms: 10 })
      expect(result[:episodes].first.details).to eq({ ms: 10 })
    end

    it "keeps at most 2× window episodes" do
      state = base_state.merge(window: 3)
      7.times do |i|
        state = h.call(:record_episode, state, action: :"a#{i}", outcome: :success)
      end
      expect(state[:episodes].size).to eq(6) # 2 × window
    end
  end

  # ── :reflect (heuristic) ────────────────────────────────────────────────────
  describe "on :reflect — heuristic" do
    it "returns a ReflectionRecord" do
      state = base_state
      2.times { state = h.call(:record_episode, state, action: :work, outcome: :success) }
      state = h.call(:record_episode, state, action: :work, outcome: :failure)
      result = h.call(:reflect, state)
      expect(result[:reflections].last).to be_a(described_class::ReflectionRecord)
    end

    it "reflects on an empty episode list" do
      result = h.call(:reflect, base_state)
      rec = result[:reflections].last
      expect(rec.summary).to include("No episodes")
    end

    it "computes success rate in the summary" do
      state = base_state
      3.times { state = h.call(:record_episode, state, action: :ok, outcome: :success) }
      state = h.call(:record_episode, state, action: :bad, outcome: :failure)
      result = h.call(:reflect, state)
      expect(result[:reflections].last.summary).to include("75.0%")
    end

    it "lists insights" do
      state = base_state
      2.times { state = h.call(:record_episode, state, action: :fail_op, outcome: :failure) }
      result = h.call(:reflect, state)
      insights = result[:reflections].last.insights
      expect(insights).to be_an(Array)
      expect(insights).not_to be_empty
    end

    it "proposes a patch when success rate < 50%" do
      state = base_state
      3.times { state = h.call(:record_episode, state, action: :bad, outcome: :failure) }
      result = h.call(:reflect, state)
      expect(result[:reflections].last.patch).not_to be_nil
    end

    it "does not propose a patch when success rate is high" do
      state = base_state
      5.times { state = h.call(:record_episode, state, action: :ok, outcome: :success) }
      result = h.call(:reflect, state)
      expect(result[:reflections].last.patch).to be_nil
    end
  end

  # ── :reflect (LLM) ──────────────────────────────────────────────────────────
  describe "on :reflect — LLM" do
    let(:llm) { ->(reflection_prompt:) { "LLM says: looks good." } }

    it "calls the LLM and stores its response as summary" do
      state = base_state.merge(llm: llm)
      state = h.call(:record_episode, state, action: :work, outcome: :success)
      result = h.call(:reflect, state)
      expect(result[:reflections].last.summary).to include("LLM says")
    end

    it "falls back to heuristic when LLM raises" do
      bad_llm = ->(**) { raise "oops" }
      state   = base_state.merge(llm: bad_llm)
      state   = h.call(:record_episode, state, action: :x, outcome: :failure)
      expect { h.call(:reflect, state) }.not_to raise_error
      result = h.call(:reflect, state)
      expect(result[:reflections].last.summary).to be_a(String)
    end
  end

  # ── :apply_patch ───────────────────────────────────────────────────────────
  describe "on :apply_patch" do
    it "increments patches_applied" do
      result = h.call(:apply_patch, base_state, patch: "reduce concurrency")
      expect(result[:patches_applied]).to eq(1)
    end

    it "stores the patch entry" do
      result = h.call(:apply_patch, base_state, patch: "add retries")
      expect(result[:patches].first[:patch]).to eq("add retries")
    end
  end

  # ── sync queries ────────────────────────────────────────────────────────────
  describe "on :status" do
    it "returns a StatusInfo struct" do
      result = h.call(:status, base_state)
      expect(result).to be_a(described_class::StatusInfo)
    end

    it "counts episodes and reflections" do
      state = base_state
      state = h.call(:record_episode, state, action: :a, outcome: :success)
      state = h.call(:reflect, state)
      status = h.call(:status, state)
      expect(status.episodes).to eq(1)
      expect(status.reflections).to eq(1)
    end

    it "reports last_reflected_at after a reflection" do
      state  = h.call(:reflect, base_state)
      status = h.call(:status, state)
      expect(status.last_reflected_at).to be_a(Time)
    end
  end

  describe "on :reflections" do
    it "returns an Array" do
      expect(h.call(:reflections, base_state)).to eq([])
    end
  end

  describe "on :episodes" do
    it "returns an Array" do
      state = h.call(:record_episode, base_state, action: :x, outcome: :success)
      expect(h.call(:episodes, state)).to be_an(Array)
    end
  end

  # ── :configure ─────────────────────────────────────────────────────────────
  describe "on :configure" do
    it "updates window" do
      result = h.call(:configure, base_state, window: 100)
      expect(result[:window]).to eq(100)
    end

    it "updates llm" do
      my_llm = ->(**) { "ok" }
      result = h.call(:configure, base_state, llm: my_llm)
      expect(result[:llm]).to eq(my_llm)
    end
  end

  # ── :reset ─────────────────────────────────────────────────────────────────
  describe "on :reset" do
    it "clears episodes and reflections" do
      state = base_state
      state = h.call(:record_episode, state, action: :x, outcome: :success)
      state = h.call(:reflect, state)
      result = h.call(:reset, state)
      expect(result[:episodes]).to be_empty
      expect(result[:reflections]).to be_empty
      expect(result[:patches_applied]).to eq(0)
    end
  end
end
