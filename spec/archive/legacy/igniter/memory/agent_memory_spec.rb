# frozen_string_literal: true

require "igniter/core/memory"

RSpec.describe Igniter::Memory::AgentMemory do
  let(:store)    { Igniter::Memory::Stores::InMemory.new }
  let(:agent_id) { "TestAgent:99" }

  subject(:memory) { described_class.new(store: store, agent_id: agent_id) }

  # ── record ────────────────────────────────────────────────────────────────

  describe "#record" do
    it "delegates to store with the agent_id pre-filled" do
      ep = memory.record(type: :tool_call, content: "did something")

      expect(ep).to be_a(Igniter::Memory::Episode)
      expect(ep.agent_id).to eq(agent_id)
      expect(ep.type).to eq(:tool_call)
      expect(ep.content).to eq("did something")
    end

    it "passes outcome and importance to the store" do
      ep = memory.record(type: :response, content: "result", outcome: "success", importance: 0.8)
      expect(ep.outcome).to eq("success")
      expect(ep.importance).to eq(0.8)
    end
  end

  # ── recall ────────────────────────────────────────────────────────────────

  describe "#recall" do
    before do
      memory.record(type: :t, content: "ruby tips")
      memory.record(type: :t, content: "python guide")
    end

    it "delegates to store#retrieve with agent_id pre-filled" do
      result = memory.recall(query: "ruby")
      expect(result.size).to eq(1)
      expect(result.first.content).to eq("ruby tips")
    end

    it "returns last N when no query" do
      result = memory.recall(limit: 1)
      expect(result.size).to eq(1)
    end
  end

  # ── remember / facts ─────────────────────────────────────────────────────

  describe "#remember and #facts" do
    it "delegates store_fact with agent_id pre-filled" do
      memory.remember(:timezone, "UTC")
      result = memory.facts
      expect(result["timezone"]).to be_a(Igniter::Memory::Fact)
      expect(result["timezone"].value).to eq("UTC")
    end

    it "delegates facts to store#facts" do
      memory.remember(:lang, "en")
      expect(memory.facts.keys).to include("lang")
    end

    it "passes confidence through" do
      memory.remember(:k, "v", confidence: 0.42)
      expect(memory.facts["k"].confidence).to eq(0.42)
    end
  end

  # ── recent ────────────────────────────────────────────────────────────────

  describe "#recent" do
    before { 5.times { |i| memory.record(type: :t, content: "ep #{i}") } }

    it "delegates to store#episodes with agent_id pre-filled" do
      result = memory.recent(last: 3)
      expect(result.size).to eq(3)
    end

    it "filters by type" do
      memory.record(type: :special, content: "unique")
      result = memory.recent(last: 10, type: :special)
      expect(result.size).to eq(1)
      expect(result.first.type).to eq(:special)
    end
  end

  # ── should_reflect? ───────────────────────────────────────────────────────

  describe "#should_reflect?" do
    it "returns false when fewer than 5 failures in recent window" do
      4.times { memory.record(type: :t, content: "fail", outcome: "failure") }
      expect(memory.should_reflect?).to be false
    end

    it "returns true when >= 5 failures in recent window" do
      5.times { memory.record(type: :t, content: "fail", outcome: "failure") }
      expect(memory.should_reflect?).to be true
    end
  end

  # ── reflect ───────────────────────────────────────────────────────────────

  describe "#reflect" do
    before { 3.times { memory.record(type: :t, content: "event", outcome: "failure") } }

    it "returns a ReflectionRecord" do
      rec = memory.reflect
      expect(rec).to be_a(Igniter::Memory::ReflectionRecord)
      expect(rec.agent_id).to eq(agent_id)
      expect(rec.summary).to be_a(String)
    end
  end

  # ── session_id propagation ────────────────────────────────────────────────

  describe "session_id propagation" do
    subject(:sessioned_memory) do
      described_class.new(store: store, agent_id: agent_id, session_id: "sess-1")
    end

    it "attaches session_id to recorded episodes" do
      ep = sessioned_memory.record(type: :t, content: "with session")
      expect(ep.session_id).to eq("sess-1")
    end
  end
end
