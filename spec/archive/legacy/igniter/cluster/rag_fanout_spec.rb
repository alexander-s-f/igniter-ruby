# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter::Cluster RAG Fan-out (Phase 7)" do
  let(:now)         { Time.utc(2026, 4, 18, 12, 0, 0) }
  let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 30).iso8601 }

  def make_obs(name, capabilities: [:rag], trust_status: :trusted)
    meta = {
      mesh: { observed_at: observed_at, confidence: 1.0, hops: 0, origin: name },
      mesh_trust: { status: trust_status.to_s, trusted: trust_status == :trusted }
    }
    Igniter::Cluster::Mesh::NodeObservation.new(
      name: name, url: "http://#{name}:4567",
      capabilities: capabilities, tags: [],
      metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(meta, now: now)
    )
  end

  def make_shard(name, *texts)
    shard = Igniter::Cluster::RAG::KnowledgeShard.new(name: name)
    texts.each { |t| shard.add(t) }
    shard
  end

  # Stub adapter — returns a fixed array of results for any call
  def stub_adapter(results_by_url = {})
    lambda do |url, _query, observation: nil|
      (results_by_url[url] || []).map do |content|
        chunk = Igniter::Cluster::RAG::Chunk.build(content)
        Igniter::Cluster::RAG::RetrievalResult.new(
          chunk: chunk, score: 0.8, source: url, observation: observation
        )
      end
    end
  end

  def stub_registry(observations)
    registry = Igniter::Cluster::Mesh::PeerRegistry.new
    observations.each do |obs|
      peer = Igniter::Cluster::Mesh::Peer.new(
        name: obs.name, url: obs.url,
        capabilities: obs.capabilities, tags: [], metadata: {}
      )
      registry.register(peer)
      allow(registry).to receive(:observations).with(now: now).and_return(observations)
    end
    allow(registry).to receive(:observations).with(now: now).and_return(observations)
    registry
  end

  # ── FanoutRetriever ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::RAG::FanoutRetriever do
    subject(:retriever) do
      described_class.new(
        registry:      registry,
        local_shard:   local_shard,
        adapter:       adapter,
        now:           now,
        require_trust: true
      )
    end

    let(:local_shard) { make_shard("local", "Ruby closures capture the environment") }
    let(:registry)    { stub_registry([]) }
    let(:adapter)     { stub_adapter }

    context "with no remote peers" do
      it "returns only local shard results" do
        results = retriever.retrieve("Ruby closures")
        expect(results).not_to be_empty
        expect(results.map(&:source)).to all(eq("local"))
      end
    end

    context "with :rag-capable trusted peers" do
      let(:node_a) { make_obs("node-a") }
      let(:node_b) { make_obs("node-b") }
      let(:registry) do
        stub_registry([node_a, node_b])
      end
      let(:adapter) do
        stub_adapter(
          "http://node-a:4567" => ["Elixir processes are isolated"],
          "http://node-b:4567" => ["Go channels enable concurrency"]
        )
      end

      it "includes results from remote peers" do
        results = retriever.retrieve("processes")
        sources = results.map(&:source)
        expect(sources).to include("http://node-a:4567")
      end

      it "merges local and remote results" do
        results = retriever.retrieve("Ruby closures processes")
        sources = results.map(&:source).uniq
        expect(sources.size).to be >= 1
      end

      it "deduplicates identical content across shards" do
        dup_adapter = stub_adapter(
          "http://node-a:4567" => ["Ruby closures capture the environment"],
          "http://node-b:4567" => ["Ruby closures capture the environment"]
        )
        r = described_class.new(
          registry: registry, local_shard: local_shard, adapter: dup_adapter,
          now: now, require_trust: true
        )
        results = r.retrieve("Ruby closures")
        ids = results.map(&:id)
        expect(ids.uniq.size).to eq(ids.size)
      end

      it "respects the limit" do
        results = retriever.retrieve("Ruby", limit: 1)
        expect(results.size).to be <= 1
      end
    end

    context "when require_trust: true" do
      let(:untrusted) { make_obs("bad-node", trust_status: :unknown) }
      let(:trusted)   { make_obs("good-node") }
      let(:registry)  { stub_registry([untrusted, trusted]) }
      let(:adapter) do
        stub_adapter(
          "http://bad-node:4567"  => ["untrusted content"],
          "http://good-node:4567" => ["trusted content"]
        )
      end

      it "skips untrusted peers" do
        results = retriever.retrieve("content")
        sources = results.map(&:source)
        expect(sources).not_to include("http://bad-node:4567")
        expect(sources).to include("http://good-node:4567")
      end
    end

    context "when require_trust: false" do
      let(:untrusted) { make_obs("shaky-node", trust_status: :unknown) }
      let(:registry)  { stub_registry([untrusted]) }
      let(:adapter) do
        stub_adapter("http://shaky-node:4567" => ["unverified content"])
      end

      subject(:retriever) do
        described_class.new(
          registry: registry, local_shard: local_shard,
          adapter: adapter, now: now, require_trust: false
        )
      end

      it "includes results from untrusted peers" do
        results = retriever.retrieve("content")
        sources = results.map(&:source)
        expect(sources).to include("http://shaky-node:4567")
      end
    end

    context "when a peer's adapter raises" do
      let(:flaky) { make_obs("flaky-node") }
      let(:registry) { stub_registry([flaky]) }
      let(:adapter)  { ->(_url, _q, observation: nil) { raise "network error" } }

      it "degrades gracefully and returns local results" do
        results = retriever.retrieve("Ruby closures")
        expect(results).not_to be_empty
        expect { results }.not_to raise_error
      end
    end

    context "without a local shard" do
      subject(:retriever) do
        described_class.new(
          registry: registry, local_shard: nil,
          adapter: adapter, now: now, require_trust: true
        )
      end
      let(:node_a) { make_obs("node-a") }
      let(:registry) { stub_registry([node_a]) }
      let(:adapter) do
        stub_adapter("http://node-a:4567" => ["remote only content"])
      end

      it "returns only remote results" do
        results = retriever.retrieve("remote")
        expect(results.map(&:source)).to all(eq("http://node-a:4567"))
      end
    end

    context "when no peers have :rag capability" do
      let(:non_rag) { make_obs("db-node", capabilities: [:database]) }
      let(:registry) { stub_registry([non_rag]) }
      let(:adapter) do
        ->(url, _q, observation: nil) { raise "should not be called for non-rag peer" }
      end

      it "does not call the adapter for non-rag peers" do
        expect { retriever.retrieve("anything") }.not_to raise_error
      end
    end

    it "accepts a RetrievalQuery directly" do
      query = Igniter::Cluster::RAG::RetrievalQuery.new(text: "Ruby closures", limit: 5)
      results = retriever.retrieve(query)
      expect(results).to be_an(Array)
    end
  end

  # ── NetHttpAdapter (serialization unit tests) ─────────────────────────────────

  describe Igniter::Cluster::RAG::NetHttpAdapter do
    subject(:adapter) { described_class.new(timeout: 2) }

    it "returns empty array on network failure" do
      # Pointing to a port nothing listens on
      result = adapter.call("http://127.0.0.1:19999", Igniter::Cluster::RAG::RetrievalQuery.new(text: "test"))
      expect(result).to eq([])
    end

    it "is instantiable with custom timeout" do
      a = described_class.new(timeout: 10)
      expect(a).to be_a(described_class)
    end
  end

  # ── Mesh.retrieve distributed: true integration ───────────────────────────────

  describe "Mesh.retrieve distributed: true" do
    before { Igniter::Cluster::Mesh.reset! }
    after  { Igniter::Cluster::Mesh.reset! }

    it "falls back to local shard when no peers registered" do
      Igniter::Cluster::Mesh.shard.add("Ruby closures capture their environment", tags: [:ruby])
      results = Igniter::Cluster::Mesh.retrieve("closures", distributed: true)
      expect(results).not_to be_empty
      expect(results.first.source).to eq(Igniter::Cluster::Mesh.shard.name)
    end

    it "accepts injectable http_adapter for testing" do
      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name         = "test-node"
        c.local_capabilities = [:rag]
      end
      Igniter::Cluster::Mesh.shard.add("local knowledge about closures")

      # no remote peers, so adapter never called — just verifying it wires through
      custom_adapter = stub_adapter
      results = Igniter::Cluster::Mesh.retrieve(
        "closures", distributed: true, http_adapter: custom_adapter
      )
      expect(results).not_to be_empty
    end

    it "distributed: false (default) still works" do
      Igniter::Cluster::Mesh.shard.add("some content about Ruby")
      results = Igniter::Cluster::Mesh.retrieve("Ruby")
      expect(results).not_to be_empty
    end
  end

  end
