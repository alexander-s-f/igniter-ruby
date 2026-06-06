# frozen_string_literal: true

require "igniter/core/memory"

RSpec.describe Igniter::Memory::ReflectionCycle do
  let(:store)    { Igniter::Memory::Stores::InMemory.new }
  let(:agent_id) { "CycleAgent:1" }

  subject(:cycle) { described_class.new(store: store) }

  # ── should_reflect? ───────────────────────────────────────────────────────

  describe "#should_reflect?" do
    it "returns false when there are fewer than 5 failures" do
      4.times { store.record(agent_id: agent_id, type: :t, content: "fail", outcome: "failure") }
      expect(cycle.should_reflect?(agent_id: agent_id)).to be false
    end

    it "returns true when there are exactly 5 failures" do
      5.times { store.record(agent_id: agent_id, type: :t, content: "fail", outcome: "failure") }
      expect(cycle.should_reflect?(agent_id: agent_id)).to be true
    end

    it "returns true when there are more than 5 failures" do
      8.times { store.record(agent_id: agent_id, type: :t, content: "fail", outcome: "failure") }
      expect(cycle.should_reflect?(agent_id: agent_id)).to be true
    end

    it "counts only 'failure' outcomes (not nil or 'success')" do
      3.times { store.record(agent_id: agent_id, type: :t, content: "ok",   outcome: "success") }
      3.times { store.record(agent_id: agent_id, type: :t, content: "x",    outcome: nil) }
      2.times { store.record(agent_id: agent_id, type: :t, content: "fail", outcome: "failure") }
      expect(cycle.should_reflect?(agent_id: agent_id)).to be false
    end
  end

  # ── reflect (rule-based) ──────────────────────────────────────────────────

  describe "#reflect (rule-based)" do
    before do
      3.times { store.record(agent_id: agent_id, type: :tool_call, content: "did x", outcome: "failure") }
      2.times { store.record(agent_id: agent_id, type: :response,  content: "did y", outcome: "failure") }
      store.record(agent_id: agent_id, type: :tool_call, content: "did z", outcome: "success")
    end

    it "returns a ReflectionRecord" do
      rec = cycle.reflect(agent_id: agent_id)
      expect(rec).to be_a(Igniter::Memory::ReflectionRecord)
    end

    it "sets the agent_id on the reflection" do
      rec = cycle.reflect(agent_id: agent_id)
      expect(rec.agent_id).to eq(agent_id)
    end

    it "includes failure counts in the summary" do
      rec = cycle.reflect(agent_id: agent_id)
      expect(rec.summary).to match(%r{5/6 failures}i)
    end

    it "mentions the top failure type in the summary" do
      rec = cycle.reflect(agent_id: agent_id)
      expect(rec.summary).to include("tool_call")
    end

    it "persists the reflection in the store" do
      cycle.reflect(agent_id: agent_id)
      records = store.reflections(agent_id: agent_id)
      expect(records.size).to eq(1)
    end

    it "sets system_patch to nil (no LLM)" do
      rec = cycle.reflect(agent_id: agent_id)
      expect(rec.system_patch).to be_nil
    end
  end

  # ── reflect with LLM ─────────────────────────────────────────────────────

  describe "#reflect with LLM" do
    let(:llm_double) do
      double("LLM", call: { summary: "LLM summary", system_patch: "Be better." })
    end

    subject(:llm_cycle) { described_class.new(store: store, llm: llm_double) }

    before do
      2.times { store.record(agent_id: agent_id, type: :t, content: "ep", outcome: "failure") }
    end

    it "calls the LLM with episodes and current_system_prompt" do
      expect(llm_double).to receive(:call).with(
        hash_including(
          episodes: be_an(Array),
          current_system_prompt: "Be concise."
        )
      ).and_return({ summary: "LLM summary", system_patch: "Be better." })

      llm_cycle.reflect(agent_id: agent_id, current_system_prompt: "Be concise.")
    end

    it "uses the LLM summary in the ReflectionRecord" do
      rec = llm_cycle.reflect(agent_id: agent_id, current_system_prompt: nil)
      expect(rec.summary).to eq("LLM summary")
    end

    it "stores the system_patch from the LLM" do
      rec = llm_cycle.reflect(agent_id: agent_id, current_system_prompt: nil)
      expect(rec.system_patch).to eq("Be better.")
    end
  end

  # ── custom thresholds ────────────────────────────────────────────────────

  describe "custom failure_threshold" do
    subject(:strict_cycle) { described_class.new(store: store, failure_threshold: 2) }

    it "triggers at the custom threshold" do
      2.times { store.record(agent_id: agent_id, type: :t, content: "f", outcome: "failure") }
      expect(strict_cycle.should_reflect?(agent_id: agent_id)).to be true
    end

    it "does not trigger below the custom threshold" do
      store.record(agent_id: agent_id, type: :t, content: "f", outcome: "failure")
      expect(strict_cycle.should_reflect?(agent_id: agent_id)).to be false
    end
  end
end
