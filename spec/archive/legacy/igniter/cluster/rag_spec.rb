# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::RAG do
  # ── Chunk ─────────────────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::Chunk do
    let(:chunk) { described_class.build("Ruby closures capture their environment", tags: [:ruby, :closures]) }

    it "has a content-addressed id (16 hex chars)" do
      expect(chunk.id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "same content produces same id (idempotent addressing)" do
      other = described_class.build("Ruby closures capture their environment")
      expect(chunk.id).to eq(other.id)
    end

    it "different content produces different id" do
      other = described_class.build("Elixir processes are isolated")
      expect(chunk.id).not_to eq(other.id)
    end

    it "stores tags as symbols" do
      expect(chunk.tags).to eq(%i[ruby closures])
    end

    it "tag? returns true for present tag" do
      expect(chunk.tag?(:ruby)).to be true
    end

    it "tag? returns false for absent tag" do
      expect(chunk.tag?(:elixir)).to be false
    end

    it "stores metadata" do
      c = described_class.build("text", metadata: { source: "handbook" })
      expect(c.metadata[:source]).to eq("handbook")
    end

    it "is frozen" do
      expect(chunk).to be_frozen
    end

    it "serializes to hash" do
      h = chunk.to_h
      expect(h[:id]).to eq(chunk.id)
      expect(h[:content]).to eq("Ruby closures capture their environment")
      expect(h[:tags]).to eq(%i[ruby closures])
    end
  end

  # ── RetrievalQuery ────────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::RetrievalQuery do
    it "stores text, tags, limit, min_score" do
      q = described_class.new(text: "closures", tags: [:ruby], limit: 5, min_score: 0.1)
      expect(q.text).to eq("closures")
      expect(q.tags).to eq([:ruby])
      expect(q.limit).to eq(5)
      expect(q.min_score).to eq(0.1)
    end

    it "coerces tags to symbols" do
      q = described_class.new(text: "test", tags: ["ruby", "closures"])
      expect(q.tags).to eq(%i[ruby closures])
    end

    it "is frozen" do
      expect(described_class.new(text: "test")).to be_frozen
    end

    it "clamps limit to minimum 1" do
      q = described_class.new(text: "test", limit: 0)
      expect(q.limit).to eq(1)
    end

    it "serializes to hash" do
      q = described_class.new(text: "test", tags: [:ruby], limit: 3, min_score: 0.2)
      expect(q.to_h).to eq({ text: "test", tags: [:ruby], limit: 3, min_score: 0.2 })
    end
  end

  # ── RetrievalResult ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::RetrievalResult do
    let(:chunk) { Igniter::Cluster::RAG::Chunk.build("Ruby closures", tags: [:ruby]) }

    it "exposes chunk attributes" do
      r = described_class.new(chunk: chunk, score: 0.8, source: "node-a")
      expect(r.id).to eq(chunk.id)
      expect(r.content).to eq("Ruby closures")
      expect(r.tags).to eq([:ruby])
    end

    it "trusted? defaults to true when no observation" do
      r = described_class.new(chunk: chunk, score: 0.8, source: "local")
      expect(r.trusted?).to be true
    end

    it "composite_score equals score when local (no observation)" do
      r = described_class.new(chunk: chunk, score: 0.8, source: "local")
      expect(r.composite_score).to be_within(0.001).of(0.8)
    end

    it "is frozen" do
      r = described_class.new(chunk: chunk, score: 0.5, source: "x")
      expect(r).to be_frozen
    end

    it "serializes to hash" do
      r = described_class.new(chunk: chunk, score: 0.7, source: "node-a")
      h = r.to_h
      expect(h[:id]).to eq(chunk.id)
      expect(h[:score]).to eq(0.7)
      expect(h[:source]).to eq("node-a")
    end

    context "with a NodeObservation" do
      let(:now)         { Time.utc(2026, 4, 18, 12, 0, 0) }
      let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 30).iso8601 }

      def make_obs(trust_status:, confidence: 1.0)
        meta = {
          mesh: { observed_at: observed_at, confidence: confidence, hops: 0, origin: "node" },
          mesh_trust: { status: trust_status.to_s, trusted: trust_status == :trusted }
        }
        Igniter::Cluster::Mesh::NodeObservation.new(
          name: "node", url: "http://node:4567", capabilities: [], tags: [],
          metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(meta, now: now)
        )
      end

      it "composite_score is full for trusted peer" do
        obs = make_obs(trust_status: :trusted, confidence: 1.0)
        r   = described_class.new(chunk: chunk, score: 0.8, source: "node", observation: obs)
        expect(r.composite_score).to be_within(0.001).of(0.8)
      end

      it "composite_score is reduced for unknown peer" do
        obs = make_obs(trust_status: :unknown, confidence: 1.0)
        r   = described_class.new(chunk: chunk, score: 0.8, source: "node", observation: obs)
        # trust_factor = 0.85 for non-trusted
        expect(r.composite_score).to be < 0.8
      end

      it "composite_score is reduced when confidence is lower" do
        obs_full = make_obs(trust_status: :trusted, confidence: 1.0)
        obs_low  = make_obs(trust_status: :trusted, confidence: 0.5)
        r_full   = described_class.new(chunk: chunk, score: 0.8, source: "node", observation: obs_full)
        r_low    = described_class.new(chunk: chunk, score: 0.8, source: "node", observation: obs_low)
        expect(r_low.composite_score).to be < r_full.composite_score
      end
    end
  end

  # ── KnowledgeShard ────────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::KnowledgeShard do
    subject(:shard) { described_class.new(name: "test-shard") }

    it "starts empty" do
      expect(shard.size).to eq(0)
      expect(shard.empty?).to be true
    end

    describe "#add" do
      it "returns a Chunk" do
        chunk = shard.add("Ruby closures bind at creation time", tags: [:ruby])
        expect(chunk).to be_a(Igniter::Cluster::RAG::Chunk)
      end

      it "increments size" do
        shard.add("first chunk")
        shard.add("second chunk")
        expect(shard.size).to eq(2)
      end

      it "is idempotent for identical content" do
        shard.add("same content")
        shard.add("same content")
        expect(shard.size).to eq(1)
      end

      it "stores different content as separate chunks" do
        shard.add("chunk one")
        shard.add("chunk two")
        expect(shard.size).to eq(2)
      end
    end

    describe "#get" do
      it "retrieves a chunk by id" do
        chunk = shard.add("find me by id")
        expect(shard.get(chunk.id)).to eq(chunk)
      end

      it "returns nil for unknown id" do
        expect(shard.get("nonexistent")).to be_nil
      end
    end

    describe "#remove" do
      it "removes a chunk and returns it" do
        chunk = shard.add("to remove")
        removed = shard.remove(chunk.id)
        expect(removed).to eq(chunk)
        expect(shard.get(chunk.id)).to be_nil
      end

      it "returns nil when chunk is absent" do
        expect(shard.remove("ghost")).to be_nil
      end
    end

    describe "#search" do
      before do
        shard.add("Ruby closures capture their surrounding environment", tags: [:ruby, :closures])
        shard.add("Elixir processes are isolated by default", tags: [:elixir])
        shard.add("Ruby blocks and closures differ in subtle ways", tags: [:ruby])
        shard.add("Memory management in garbage-collected languages", tags: [:gc])
      end

      it "returns an array of RetrievalResult" do
        results = shard.search("closures")
        expect(results).to all(be_a(Igniter::Cluster::RAG::RetrievalResult))
      end

      it "returns relevant chunks first" do
        results = shard.search("Ruby closures")
        expect(results.first.content).to include("closures")
      end

      it "returns chunks ordered by score descending" do
        results = shard.search("Ruby closures")
        scores = results.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
      end

      it "respects the limit" do
        results = shard.search("Ruby", limit: 2)
        expect(results.size).to be <= 2
      end

      it "filters by tags" do
        results = shard.search("", tags: [:elixir])
        expect(results.map(&:tags)).to all(include(:elixir))
      end

      it "returns empty when no chunks match tags" do
        results = shard.search("closures", tags: [:haskell])
        expect(results).to be_empty
      end

      it "applies min_score filter" do
        results = shard.search("Ruby closures environment", min_score: 0.9)
        results.each { |r| expect(r.score).to be >= 0.9 }
      end

      it "returns empty for a query with no matches above min_score" do
        results = shard.search("completely unrelated xyz abc", min_score: 0.8)
        expect(results).to be_empty
      end

      it "accepts a RetrievalQuery object" do
        query   = Igniter::Cluster::RAG::RetrievalQuery.new(text: "Ruby", tags: [:ruby], limit: 5)
        results = shard.search(query)
        expect(results).not_to be_empty
        expect(results.map(&:tags)).to all(include(:ruby))
      end

      it "sets source to shard name on each result" do
        results = shard.search("Ruby")
        expect(results.map(&:source)).to all(eq("test-shard"))
      end

      it "returns empty for an empty query string (no text, no tags)" do
        results = shard.search("")
        expect(results).to be_empty
      end
    end

    describe "#clear" do
      it "removes all chunks" do
        shard.add("a")
        shard.add("b")
        shard.clear
        expect(shard.empty?).to be true
      end
    end
  end

  # ── Ranker ───────────────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::Ranker do
    subject(:ranker) { described_class.new }

    def result(content, score, source: "local")
      chunk = Igniter::Cluster::RAG::Chunk.build(content)
      Igniter::Cluster::RAG::RetrievalResult.new(chunk: chunk, score: score, source: source)
    end

    it "merges multiple arrays and orders by composite_score descending" do
      r1 = result("high relevance text", 0.9, source: "a")
      r2 = result("medium text result", 0.5, source: "b")
      r3 = result("lower relevance", 0.3, source: "c")
      merged = ranker.merge([r2], [r1, r3])
      expect(merged.map(&:score)).to eq([0.9, 0.5, 0.3])
    end

    it "deduplicates by chunk id (keeps highest composite_score copy)" do
      chunk = Igniter::Cluster::RAG::Chunk.build("shared content")
      r_high = Igniter::Cluster::RAG::RetrievalResult.new(chunk: chunk, score: 0.9, source: "a")
      r_low  = Igniter::Cluster::RAG::RetrievalResult.new(chunk: chunk, score: 0.4, source: "b")
      merged = ranker.merge([r_high], [r_low])
      expect(merged.size).to eq(1)
      expect(merged.first.score).to eq(0.9)
    end

    it "respects the limit" do
      results = (1..5).map { |i| result("chunk #{i}", i.to_f / 5) }
      merged  = ranker.merge(results, limit: 3)
      expect(merged.size).to eq(3)
    end

    it "returns empty for empty input" do
      expect(ranker.merge([], [])).to eq([])
    end

    it "skips deduplication when deduplicate: false" do
      chunk = Igniter::Cluster::RAG::Chunk.build("same content")
      r1 = Igniter::Cluster::RAG::RetrievalResult.new(chunk: chunk, score: 0.8, source: "a")
      r2 = Igniter::Cluster::RAG::RetrievalResult.new(chunk: chunk, score: 0.6, source: "b")
      merged = ranker.merge([r1], [r2], deduplicate: false)
      expect(merged.size).to eq(2)
    end
  end

  # ── Mesh.shard / Mesh.retrieve integration ────────────────────────────────────

  describe "Igniter::Cluster::Mesh RAG integration" do
    before { Igniter::Cluster::Mesh.reset! }
    after  { Igniter::Cluster::Mesh.reset! }

    it "Mesh.shard lazily creates a KnowledgeShard" do
      expect(Igniter::Cluster::Mesh.shard).to be_a(Igniter::Cluster::RAG::KnowledgeShard)
    end

    it "Mesh.shard returns the same instance on repeated calls" do
      s1 = Igniter::Cluster::Mesh.shard
      s2 = Igniter::Cluster::Mesh.shard
      expect(s1).to equal(s2)
    end

    it "Mesh.shard uses peer_name as shard name when configured" do
      Igniter::Cluster::Mesh.configure { |c| c.peer_name = "my-node" }
      expect(Igniter::Cluster::Mesh.shard.name).to eq("my-node")
    end

    it "Mesh.retrieve searches the local shard" do
      Igniter::Cluster::Mesh.shard.add("Ruby closures capture their environment", tags: [:ruby])
      results = Igniter::Cluster::Mesh.retrieve("closures")
      expect(results).not_to be_empty
      expect(results.first.content).to include("closures")
    end

    it "Mesh.retrieve with tags filters correctly" do
      Igniter::Cluster::Mesh.shard.add("Ruby closures", tags: [:ruby])
      Igniter::Cluster::Mesh.shard.add("Elixir processes", tags: [:elixir])
      results = Igniter::Cluster::Mesh.retrieve("", tags: [:ruby])
      expect(results.map(&:tags)).to all(include(:ruby))
    end

    it "Mesh.retrieve with limit caps results" do
      5.times { |i| Igniter::Cluster::Mesh.shard.add("chunk about closures #{i}") }
      results = Igniter::Cluster::Mesh.retrieve("closures", limit: 2)
      expect(results.size).to be <= 2
    end

    it "config.knowledge_shard= accepts an externally built shard" do
      external = Igniter::Cluster::RAG::KnowledgeShard.new(name: "external")
      external.add("external knowledge")
      Igniter::Cluster::Mesh.configure { |c| c.knowledge_shard = external }
      expect(Igniter::Cluster::Mesh.shard).to equal(external)
      results = Igniter::Cluster::Mesh.retrieve("external knowledge")
      expect(results).not_to be_empty
    end
  end
end
