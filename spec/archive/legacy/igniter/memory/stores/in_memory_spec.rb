# frozen_string_literal: true

require "igniter/core/memory"

RSpec.describe Igniter::Memory::Stores::InMemory do
  subject(:store) { described_class.new }

  let(:agent_id) { "TestAgent:1" }
  let(:other_id) { "OtherAgent:2" }

  # ── record ────────────────────────────────────────────────────────────────

  describe "#record" do
    it "returns an Episode with correct fields" do
      ep = store.record(agent_id: agent_id, type: :tool_call, content: "searched web")

      expect(ep).to be_a(Igniter::Memory::Episode)
      expect(ep.agent_id).to eq(agent_id)
      expect(ep.type).to eq(:tool_call)
      expect(ep.content).to eq("searched web")
      expect(ep.outcome).to be_nil
      expect(ep.importance).to eq(0.5)
      expect(ep.id).to be_a(Integer)
      expect(ep.ts).to be_a(Integer)
    end

    it "stores outcome and importance when provided" do
      ep = store.record(
        agent_id: agent_id, type: :response, content: "hello",
        outcome: "success", importance: 0.9
      )

      expect(ep.outcome).to eq("success")
      expect(ep.importance).to eq(0.9)
    end

    it "stores session_id when provided" do
      ep = store.record(agent_id: agent_id, type: :event, content: "started",
                        session_id: "sess-42")
      expect(ep.session_id).to eq("sess-42")
    end

    it "assigns unique ids to successive episodes" do
      ep1 = store.record(agent_id: agent_id, type: :a, content: "first")
      ep2 = store.record(agent_id: agent_id, type: :a, content: "second")
      expect(ep1.id).not_to eq(ep2.id)
    end
  end

  # ── episodes ──────────────────────────────────────────────────────────────

  describe "#episodes" do
    before do
      store.record(agent_id: agent_id, type: :tool_call, content: "one")
      store.record(agent_id: agent_id, type: :response,  content: "two")
      store.record(agent_id: other_id, type: :tool_call, content: "other")
    end

    it "returns only episodes for the given agent_id" do
      result = store.episodes(agent_id: agent_id)
      expect(result.map(&:agent_id)).to all(eq(agent_id))
      expect(result.size).to eq(2)
    end

    it "respects the last: limit" do
      5.times { |i| store.record(agent_id: agent_id, type: :t, content: "ep #{i}") }
      result = store.episodes(agent_id: agent_id, last: 3)
      expect(result.size).to eq(3)
    end

    it "filters by type when specified" do
      result = store.episodes(agent_id: agent_id, type: :tool_call)
      expect(result.size).to eq(1)
      expect(result.first.content).to eq("one")
    end

    it "returns an empty array when no episodes exist for the agent" do
      expect(store.episodes(agent_id: "unknown")).to eq([])
    end
  end

  # ── retrieve ──────────────────────────────────────────────────────────────

  describe "#retrieve" do
    before do
      store.record(agent_id: agent_id, type: :t, content: "Ruby programming tips")
      store.record(agent_id: agent_id, type: :t, content: "Python best practices")
      store.record(agent_id: agent_id, type: :t, content: "ruby on rails guide")
    end

    it "returns last N episodes when query is nil" do
      result = store.retrieve(agent_id: agent_id, limit: 2)
      expect(result.size).to eq(2)
    end

    it "does case-insensitive substring match" do
      result = store.retrieve(agent_id: agent_id, query: "ruby")
      expect(result.size).to eq(2)
      expect(result.map(&:content)).to include("Ruby programming tips", "ruby on rails guide")
    end

    it "returns empty array when query matches nothing" do
      result = store.retrieve(agent_id: agent_id, query: "javascript")
      expect(result).to eq([])
    end

    it "respects limit when query matches multiple" do
      result = store.retrieve(agent_id: agent_id, query: "ruby", limit: 1)
      expect(result.size).to eq(1)
    end

    it "filters by type in combination with query" do
      store.record(agent_id: agent_id, type: :response, content: "ruby response")
      result = store.retrieve(agent_id: agent_id, query: "ruby", type: :response)
      expect(result.all? { |e| e.type == :response }).to be true
    end
  end

  # ── store_fact / facts ────────────────────────────────────────────────────

  describe "#store_fact and #facts" do
    it "stores a fact and retrieves it" do
      store.store_fact(agent_id: agent_id, key: "tz", value: "UTC")
      result = store.facts(agent_id: agent_id)

      expect(result).to be_a(Hash)
      expect(result.keys).to eq(["tz"])
      expect(result["tz"]).to be_a(Igniter::Memory::Fact)
      expect(result["tz"].value).to eq("UTC")
    end

    it "stores key as a string even when a symbol is given" do
      store.store_fact(agent_id: agent_id, key: :timezone, value: "EST")
      result = store.facts(agent_id: agent_id)
      expect(result.keys).to eq(["timezone"])
    end

    it "overwrites a fact with the same key" do
      store.store_fact(agent_id: agent_id, key: "lang", value: "en")
      store.store_fact(agent_id: agent_id, key: "lang", value: "fr")
      result = store.facts(agent_id: agent_id)
      expect(result["lang"].value).to eq("fr")
    end

    it "stores confidence" do
      store.store_fact(agent_id: agent_id, key: "k", value: "v", confidence: 0.7)
      expect(store.facts(agent_id: agent_id)["k"].confidence).to eq(0.7)
    end

    it "returns empty hash when no facts stored" do
      expect(store.facts(agent_id: "ghost")).to eq({})
    end

    it "does not leak facts between agents" do
      store.store_fact(agent_id: agent_id, key: "k", value: "v1")
      store.store_fact(agent_id: other_id, key: "k", value: "v2")
      expect(store.facts(agent_id: agent_id)["k"].value).to eq("v1")
      expect(store.facts(agent_id: other_id)["k"].value).to eq("v2")
    end
  end

  # ── record_reflection ────────────────────────────────────────────────────

  describe "#record_reflection" do
    it "returns a ReflectionRecord with correct fields" do
      rec = store.record_reflection(agent_id: agent_id, summary: "All good")

      expect(rec).to be_a(Igniter::Memory::ReflectionRecord)
      expect(rec.agent_id).to eq(agent_id)
      expect(rec.summary).to eq("All good")
      expect(rec.system_patch).to be_nil
      expect(rec.applied).to be false
      expect(rec.id).to be_a(Integer)
      expect(rec.ts).to be_a(Integer)
    end

    it "stores system_patch when provided" do
      rec = store.record_reflection(agent_id: agent_id, summary: "s",
                                    system_patch: "Be more concise.")
      expect(rec.system_patch).to eq("Be more concise.")
    end
  end

  # ── reflections ──────────────────────────────────────────────────────────

  describe "#reflections" do
    before do
      store.record_reflection(agent_id: agent_id, summary: "first",  applied: false)
      store.record_reflection(agent_id: agent_id, summary: "second", applied: true)
      store.record_reflection(agent_id: other_id, summary: "other")
    end

    it "returns all reflections for the agent" do
      result = store.reflections(agent_id: agent_id)
      expect(result.size).to eq(2)
    end

    it "filters by applied: false" do
      result = store.reflections(agent_id: agent_id, applied: false)
      expect(result.size).to eq(1)
      expect(result.first.summary).to eq("first")
    end

    it "filters by applied: true" do
      result = store.reflections(agent_id: agent_id, applied: true)
      expect(result.size).to eq(1)
      expect(result.first.summary).to eq("second")
    end

    it "does not return reflections for other agents" do
      result = store.reflections(agent_id: agent_id)
      expect(result.map(&:agent_id)).to all(eq(agent_id))
    end
  end

  # ── apply_reflection ─────────────────────────────────────────────────────

  describe "#apply_reflection" do
    it "marks the reflection as applied and returns true" do
      rec = store.record_reflection(agent_id: agent_id, summary: "old")
      expect(rec.applied).to be false

      result = store.apply_reflection(id: rec.id)
      expect(result).to be true

      updated = store.reflections(agent_id: agent_id, applied: true)
      expect(updated.size).to eq(1)
      expect(updated.first.id).to eq(rec.id)
    end

    it "returns false when the id does not exist" do
      expect(store.apply_reflection(id: 99_999)).to be false
    end
  end

  # ── clear ────────────────────────────────────────────────────────────────

  describe "#clear" do
    before do
      store.record(agent_id: agent_id, type: :t, content: "keep me not")
      store.store_fact(agent_id: agent_id, key: "k", value: "v")
      store.record_reflection(agent_id: agent_id, summary: "s")
      store.record(agent_id: other_id, type: :t, content: "keep me")
      store.store_fact(agent_id: other_id, key: "k2", value: "v2")
    end

    it "removes all data for the given agent_id" do
      store.clear(agent_id: agent_id)
      expect(store.episodes(agent_id: agent_id)).to be_empty
      expect(store.facts(agent_id: agent_id)).to be_empty
      expect(store.reflections(agent_id: agent_id)).to be_empty
    end

    it "does not remove data for other agents" do
      store.clear(agent_id: agent_id)
      expect(store.episodes(agent_id: other_id).size).to eq(1)
      expect(store.facts(agent_id: other_id).size).to eq(1)
    end
  end

  # ── thread safety ─────────────────────────────────────────────────────────

  describe "thread safety" do
    it "produces correct count when multiple threads record concurrently" do
      threads = 10.times.map do |i|
        Thread.new do
          store.record(agent_id: agent_id, type: :concurrent, content: "thread #{i}")
        end
      end
      threads.each(&:join)

      expect(store.episodes(agent_id: agent_id, last: 100).size).to eq(10)
    end
  end
end
