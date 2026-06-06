# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Mesh::MeshQL do
  let(:now) { Time.utc(2026, 4, 18, 12, 0, 0) }
  let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 0).iso8601 }

  def make_obs(name:, caps: [], tags: [], state: {}, locality: {}, trust_status: nil)
    meta = { mesh: { observed_at: observed_at, confidence: 1.0, hops: 0, origin: name } }
    meta[:mesh_state]    = state    unless state.empty?
    meta[:mesh_locality] = locality unless locality.empty?
    meta[:mesh_trust]    = { status: trust_status.to_s, trusted: trust_status == :trusted } if trust_status

    Igniter::Cluster::Mesh::NodeObservation.new(
      name:         name,
      url:          "http://#{name}:4567",
      capabilities: caps,
      tags:         tags,
      metadata:     Igniter::Cluster::Mesh::PeerMetadata.runtime(meta, now: now)
    )
  end

  let(:node_a) do
    make_obs(name: "node-a", caps: [:database, :orders], tags: [:linux],
             state: { health: "healthy", load_cpu: 0.2, load_memory: 0.3, concurrency: 1, queue_depth: 0 },
             locality: { region: "us-east-1", zone: "us-east-1a" },
             trust_status: :trusted)
  end

  let(:node_b) do
    make_obs(name: "node-b", caps: [:database], tags: [:linux],
             state: { health: "healthy", load_cpu: 0.8, load_memory: 0.9, concurrency: 10, queue_depth: 5 },
             locality: { region: "us-east-1", zone: "us-east-1b" },
             trust_status: :trusted)
  end

  let(:node_c) do
    make_obs(name: "node-c", caps: [:analytics], tags: [:darwin],
             state: { health: "degraded", load_cpu: 0.4, concurrency: 2 },
             locality: { region: "eu-central-1", zone: "eu-central-1a" },
             trust_status: :unknown)
  end

  let(:observations) { [node_a, node_b, node_c] }

  # ── Tokenizer ──────────────────────────────────────────────────────────────────

  describe "Tokenizer" do
    subject(:tokenizer) { described_class::Tokenizer }

    it "tokenizes SELECT with symbols" do
      tokens = tokenizer.run("SELECT :database, :orders")
      expect(tokens).to eq([
        [:word, "SELECT"],
        [:symbol, :database],
        [:op, ","],
        [:symbol, :orders]
      ])
    end

    it "tokenizes WHERE with metric condition" do
      tokens = tokenizer.run("WHERE load_cpu <= 0.5")
      expect(tokens).to include([:word, "WHERE"], [:word, "LOAD_CPU"], [:op, "<="], [:number, 0.5])
    end

    it "tokenizes quoted strings" do
      tokens = tokenizer.run('IN ZONE "us-east-1a"')
      expect(tokens).to include([:string, "us-east-1a"])
    end

    it "tokenizes unquoted zone names" do
      tokens = tokenizer.run("IN ZONE us-east-1a")
      expect(tokens).to include([:string, "us-east-1a"])
    end

    it "raises ParseError on unexpected characters" do
      expect { tokenizer.run("SELECT @bad") }.to raise_error(described_class::ParseError)
    end
  end

  # ── Parser / parse ────────────────────────────────────────────────────────────

  describe ".parse" do
    it "returns a ParsedQuery" do
      pq = described_class.parse("SELECT :database")
      expect(pq).to be_a(described_class::ParsedQuery)
    end

    it "parses capabilities" do
      pq = described_class.parse("SELECT :database, :orders")
      expect(pq.capabilities).to eq(%i[database orders])
    end

    it "parses SELECT *" do
      pq = described_class.parse("SELECT *")
      expect(pq.capabilities).to eq(:all)
    end

    it "parses TRUSTED condition" do
      pq = described_class.parse("SELECT :database WHERE TRUSTED")
      expect(pq.conditions).to include(type: :trusted)
    end

    it "parses HEALTHY condition" do
      pq = described_class.parse("SELECT * WHERE HEALTHY")
      expect(pq.conditions).to include(type: :healthy)
    end

    it "parses AUTHORITATIVE condition" do
      pq = described_class.parse("SELECT * WHERE AUTHORITATIVE")
      expect(pq.conditions).to include(type: :authoritative)
    end

    it "parses TAGGED condition" do
      pq = described_class.parse("SELECT * WHERE TAGGED :linux")
      expect(pq.conditions).to include(type: :tagged, value: :linux)
    end

    it "parses NOT condition" do
      pq = described_class.parse("SELECT * WHERE NOT :analytics")
      expect(pq.conditions).to include(type: :without, value: :analytics)
    end

    it "parses IN ZONE condition" do
      pq = described_class.parse('SELECT * WHERE IN ZONE "us-east-1a"')
      expect(pq.conditions).to include(type: :locality, dimension: :zone, value: "us-east-1a")
    end

    it "parses IN REGION condition (unquoted)" do
      pq = described_class.parse("SELECT * WHERE IN REGION us-east-1")
      expect(pq.conditions).to include(type: :locality, dimension: :region, value: "us-east-1")
    end

    it "parses metric condition with < operator" do
      pq = described_class.parse("SELECT * WHERE load_cpu < 0.5")
      expect(pq.conditions).to include(type: :metric, metric: :load_cpu, op: "<", value: 0.5)
    end

    it "parses metric condition with <= operator" do
      pq = described_class.parse("SELECT * WHERE concurrency <= 4")
      expect(pq.conditions).to include(type: :metric, metric: :concurrency, op: "<=", value: 4)
    end

    it "parses multiple AND conditions" do
      pq = described_class.parse("SELECT :database WHERE TRUSTED AND load_cpu < 0.5 AND IN ZONE us-east-1a")
      expect(pq.conditions.size).to eq(3)
    end

    it "parses ORDER BY ascending" do
      pq = described_class.parse("SELECT :database ORDER BY load_cpu")
      expect(pq.orderings).to eq([{ metric: :load_cpu, direction: :asc }])
    end

    it "parses ORDER BY descending" do
      pq = described_class.parse("SELECT :database ORDER BY load_cpu DESC")
      expect(pq.orderings).to eq([{ metric: :load_cpu, direction: :desc }])
    end

    it "parses multiple ORDER BY fields" do
      pq = described_class.parse("SELECT :database ORDER BY load_cpu ASC, concurrency DESC")
      expect(pq.orderings).to eq([
        { metric: :load_cpu, direction: :asc },
        { metric: :concurrency, direction: :desc }
      ])
    end

    it "parses LIMIT" do
      pq = described_class.parse("SELECT :database LIMIT 3")
      expect(pq.limit).to eq(3)
    end

    it "parses a full query" do
      source = "SELECT :database WHERE TRUSTED AND load_cpu < 0.5 AND IN ZONE us-east-1a ORDER BY load_cpu ASC LIMIT 1"
      pq = described_class.parse(source)
      expect(pq.capabilities).to eq([:database])
      expect(pq.conditions.size).to eq(3)
      expect(pq.orderings).to eq([{ metric: :load_cpu, direction: :asc }])
      expect(pq.limit).to eq(1)
    end

    it "raises ParseError when SELECT is missing" do
      expect { described_class.parse("WHERE trusted") }.to raise_error(described_class::ParseError)
    end

    it "raises ParseError on unknown WHERE token" do
      expect { described_class.parse("SELECT * WHERE INVALID_KEYWORD") }.to raise_error(described_class::ParseError)
    end
  end

  # ── ParsedQuery#to_query execution ───────────────────────────────────────────

  describe "ParsedQuery#to_query execution" do
    it "filters by capability" do
      result = described_class.run("SELECT :database", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "SELECT * returns all" do
      result = described_class.run("SELECT *", observations)
      expect(result.size).to eq(3)
    end

    it "filters TRUSTED" do
      result = described_class.run("SELECT * WHERE TRUSTED", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "filters HEALTHY" do
      result = described_class.run("SELECT * WHERE HEALTHY", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "filters metric < threshold" do
      result = described_class.run("SELECT :database WHERE load_cpu < 0.5", observations)
      expect(result.map(&:name)).to eq(["node-a"])
    end

    it "filters metric <= threshold" do
      result = described_class.run("SELECT :database WHERE load_cpu <= 0.8", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "filters IN ZONE" do
      result = described_class.run("SELECT * WHERE IN ZONE us-east-1a", observations)
      expect(result.map(&:name)).to eq(["node-a"])
    end

    it "filters IN REGION" do
      result = described_class.run('SELECT * WHERE IN REGION "us-east-1"', observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "filters NOT capability" do
      result = described_class.run("SELECT * WHERE NOT :analytics", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "orders by load_cpu ASC" do
      result = described_class.run("SELECT :database ORDER BY load_cpu ASC", observations)
      expect(result.map(&:name)).to eq(%w[node-a node-b])
    end

    it "orders by load_cpu DESC" do
      result = described_class.run("SELECT :database ORDER BY load_cpu DESC", observations)
      expect(result.map(&:name)).to eq(%w[node-b node-a])
    end

    it "applies LIMIT" do
      result = described_class.run("SELECT :database ORDER BY load_cpu LIMIT 1", observations)
      expect(result.size).to eq(1)
      expect(result.first.name).to eq("node-a")
    end

    it "executes a full real-world query" do
      source = "SELECT :database WHERE TRUSTED AND load_cpu < 0.5 AND IN ZONE us-east-1a ORDER BY load_cpu LIMIT 1"
      result = described_class.run(source, observations)
      expect(result.size).to eq(1)
      expect(result.first.name).to eq("node-a")
    end

    it "returns empty when no nodes match" do
      result = described_class.run("SELECT :billing", observations)
      expect(result).to be_empty
    end
  end

  # ── Workload dimension conditions ────────────────────────────────────────────

  describe "workload dimension" do
    def make_workload_obs(name:, caps:, failure_rate:, avg_ms: nil, degraded: false, overloaded: false)
      Igniter::Cluster::Mesh::NodeObservation.new(
        name: name, url: "http://#{name}:4567",
        capabilities: caps, tags: [],
        metadata: {
          mesh: { observed_at: observed_at, confidence: 1.0, hops: 0 },
          mesh_workload: { failure_rate: failure_rate, avg_duration_ms: avg_ms,
                           total: 10, degraded: degraded, overloaded: overloaded }.compact
        }
      )
    end

    let(:wl_healthy)   { make_workload_obs(name: "wl-a", caps: [:api], failure_rate: 0.05, avg_ms: 80) }
    let(:wl_degraded)  { make_workload_obs(name: "wl-b", caps: [:api], failure_rate: 0.7,  avg_ms: 300, degraded: true) }
    let(:wl_overloaded){ make_workload_obs(name: "wl-c", caps: [:api], failure_rate: 0.1,  avg_ms: 1500, overloaded: true) }
    let(:wl_pool)      { [wl_healthy, wl_degraded, wl_overloaded] }

    it "filters failure_rate < threshold" do
      result = described_class.run("SELECT :api WHERE failure_rate < 0.1", wl_pool)
      expect(result.map(&:name)).to eq(["wl-a"])
    end

    it "filters failure_rate >= threshold" do
      result = described_class.run("SELECT :api WHERE failure_rate >= 0.5", wl_pool)
      expect(result.map(&:name)).to eq(["wl-b"])
    end

    it "filters avg_latency_ms < threshold" do
      result = described_class.run("SELECT :api WHERE avg_latency_ms < 500", wl_pool)
      expect(result.map(&:name)).to contain_exactly("wl-a", "wl-b")
    end

    it "filters NOT DEGRADED" do
      result = described_class.run("SELECT :api WHERE NOT DEGRADED", wl_pool)
      expect(result.map(&:name)).to contain_exactly("wl-a", "wl-c")
    end

    it "filters NOT OVERLOADED" do
      result = described_class.run("SELECT :api WHERE NOT OVERLOADED", wl_pool)
      expect(result.map(&:name)).to contain_exactly("wl-a", "wl-b")
    end

    it "combines NOT DEGRADED AND NOT OVERLOADED" do
      result = described_class.run("SELECT :api WHERE NOT DEGRADED AND NOT OVERLOADED", wl_pool)
      expect(result.map(&:name)).to eq(["wl-a"])
    end

    it "orders by failure_rate ASC" do
      result = described_class.run("SELECT :api ORDER BY failure_rate ASC", wl_pool)
      expect(result.first.name).to eq("wl-a")
      expect(result.last.name).to eq("wl-b")
    end

    it "orders by avg_latency_ms DESC" do
      result = described_class.run("SELECT :api ORDER BY avg_latency_ms DESC", wl_pool)
      expect(result.first.name).to eq("wl-c")
    end

    it "ParsedQuery#to_meshql serializes NOT DEGRADED" do
      pq = described_class.parse("SELECT :api WHERE NOT DEGRADED")
      expect(pq.to_meshql).to include("NOT DEGRADED")
    end

    it "ParsedQuery#to_meshql serializes NOT OVERLOADED" do
      pq = described_class.parse("SELECT :api WHERE NOT OVERLOADED")
      expect(pq.to_meshql).to include("NOT OVERLOADED")
    end

    it "ParsedQuery#to_meshql serializes failure_rate condition" do
      pq = described_class.parse("SELECT :api WHERE failure_rate < 0.2")
      expect(pq.to_meshql).to include("failure_rate < 0.2")
    end

    it "round-trips workload conditions" do
      source = "SELECT :api WHERE NOT DEGRADED AND failure_rate < 0.3"
      pq1    = described_class.parse(source)
      pq2    = described_class.parse(pq1.to_meshql)
      expect(pq1.to_query(wl_pool).map(&:name)).to eq(pq2.to_query(wl_pool).map(&:name))
    end
  end

  # ── ParsedQuery#to_meshql (serialization) ────────────────────────────────────

  describe "ParsedQuery#to_meshql" do
    it "serializes capabilities" do
      pq = described_class.parse("SELECT :database, :orders")
      expect(pq.to_meshql).to start_with("SELECT :database, :orders")
    end

    it "serializes SELECT *" do
      pq = described_class.parse("SELECT *")
      expect(pq.to_meshql).to start_with("SELECT *")
    end

    it "serializes WHERE conditions" do
      pq = described_class.parse("SELECT :database WHERE TRUSTED AND load_cpu < 0.5")
      ql = pq.to_meshql
      expect(ql).to include("WHERE")
      expect(ql).to include("TRUSTED")
      expect(ql).to include("load_cpu < 0.5")
    end

    it "serializes IN ZONE" do
      pq = described_class.parse("SELECT * WHERE IN ZONE us-east-1a")
      expect(pq.to_meshql).to include("IN ZONE us-east-1a")
    end

    it "serializes ORDER BY" do
      pq = described_class.parse("SELECT :database ORDER BY load_cpu DESC")
      expect(pq.to_meshql).to include("ORDER BY load_cpu DESC")
    end

    it "serializes LIMIT" do
      pq = described_class.parse("SELECT :database LIMIT 5")
      expect(pq.to_meshql).to include("LIMIT 5")
    end

    it "round-trips parse → to_meshql → parse → run" do
      source = "SELECT :database WHERE TRUSTED AND load_cpu < 0.5 ORDER BY load_cpu ASC LIMIT 1"
      pq1    = described_class.parse(source)
      pq2    = described_class.parse(pq1.to_meshql)

      result1 = pq1.to_query(observations).to_a
      result2 = pq2.to_query(observations).to_a

      expect(result1.map(&:name)).to eq(result2.map(&:name))
    end
  end

  # ── Case insensitivity ────────────────────────────────────────────────────────

  describe "case insensitive keywords" do
    it "accepts lowercase keywords" do
      result = described_class.run("select :database where trusted", observations)
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "accepts mixed case" do
      result = described_class.run("Select :database Where Trusted And load_cpu < 0.5", observations)
      expect(result.map(&:name)).to eq(["node-a"])
    end
  end
end
