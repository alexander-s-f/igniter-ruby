# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Mesh::PlacementPlanner do
  let(:now)         { Time.utc(2026, 4, 18, 12, 0, 0) }
  let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 30).iso8601 }

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
    make_obs(name: "node-a",
             caps: %i[database orders],
             state: { health: "healthy", load_cpu: 0.2, load_memory: 0.3, concurrency: 1, queue_depth: 0 },
             locality: { region: "us-east-1", zone: "us-east-1a" },
             trust_status: :trusted)
  end

  let(:node_b) do
    make_obs(name: "node-b",
             caps: %i[database],
             state: { health: "healthy", load_cpu: 0.7, load_memory: 0.8, concurrency: 6, queue_depth: 3 },
             locality: { region: "us-east-1", zone: "us-east-1b" },
             trust_status: :trusted)
  end

  let(:node_c) do
    make_obs(name: "node-c",
             caps: %i[analytics],
             state: { health: "degraded", load_cpu: 0.4, concurrency: 2 },
             locality: { region: "eu-central-1", zone: "eu-central-1a" },
             trust_status: :unknown)
  end

  let(:node_d) do
    make_obs(name: "node-d",
             caps: %i[database],
             state: { health: "unknown" },
             locality: { region: "us-west-2", zone: "us-west-2a" },
             trust_status: :unknown)
  end

  let(:observations) { [node_a, node_b, node_c, node_d] }

  # ── PlacementPolicy ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::PlacementPolicy do
    it "defaults to require_health: true, require_trust: false" do
      policy = described_class.new
      expect(policy.require_health).to be true
      expect(policy.require_trust).to be false
    end

    it "raises on unknown locality_preference" do
      expect { described_class.new(locality_preference: :datacenter) }
        .to raise_error(ArgumentError, /locality_preference/)
    end

    it "applies health filter via constrain" do
      policy = described_class.new(require_health: true)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      expect(result.map(&:name)).not_to include("node-c", "node-d")
    end

    it "applies trust filter via constrain" do
      policy = described_class.new(require_trust: true)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "applies max_load_cpu filter via constrain" do
      policy = described_class.new(require_health: false, max_load_cpu: 0.5)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      # node-a (0.2) and node-c (0.4) pass; node-b (0.7) does not
      expect(result.map(&:name)).to include("node-a", "node-c")
      expect(result.map(&:name)).not_to include("node-b")
    end

    it "applies zone constraint when locality_preference: :zone" do
      policy = described_class.new(zone: "us-east-1a", locality_preference: :zone, require_health: false)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      expect(result.map(&:name)).to eq(["node-a"])
    end

    it "applies region constraint when locality_preference: :region" do
      policy = described_class.new(region: "us-east-1", locality_preference: :region, require_health: false)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      expect(result.map(&:name)).to contain_exactly("node-a", "node-b")
    end

    it "does not apply zone/region filter when locality_preference: :any" do
      policy = described_class.new(zone: "us-east-1a", locality_preference: :any, require_health: false)
      q = Igniter::Cluster::Mesh::ObservationQuery.new(observations)
      result = policy.constrain(q).to_a
      expect(result.size).to eq(observations.size)
    end

    it "returns a fully relaxed copy via #relaxed" do
      policy = described_class.new(require_trust: true, require_health: true, max_load_cpu: 0.3, zone: "us-east-1a", locality_preference: :zone)
      relaxed = policy.relaxed
      expect(relaxed.require_trust).to be false
      expect(relaxed.require_health).to be false
      expect(relaxed.max_load_cpu).to be_nil
      expect(relaxed.zone).to be_nil
      expect(relaxed.locality_preference).to eq(:any)
      expect(relaxed.degraded_fallback).to be false
    end

    it "serializes to hash" do
      policy = described_class.new(zone: "us-east-1a", require_trust: true)
      h = policy.to_h
      expect(h[:zone]).to eq("us-east-1a")
      expect(h[:require_trust]).to be true
    end
  end

  # ── PlacementDecision ─────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::PlacementDecision do
    let(:policy) { Igniter::Cluster::Mesh::PlacementPolicy.new }

    it "placed? is true when node is set" do
      decision = described_class.new(node: node_a, score: 0.9, dimensions: {}, rejected: [], degraded: false, policy: policy)
      expect(decision.placed?).to be true
      expect(decision.failed?).to be false
    end

    it "failed? is true when node is nil" do
      decision = described_class.new(node: nil, score: nil, dimensions: {}, rejected: [], degraded: false, policy: policy)
      expect(decision.failed?).to be true
      expect(decision.placed?).to be false
    end

    it "exposes url and name from the node" do
      decision = described_class.new(node: node_a, score: 0.9, dimensions: {}, rejected: [], degraded: false, policy: policy)
      expect(decision.url).to eq(node_a.url)
      expect(decision.name).to eq("node-a")
    end

    it "serializes to hash" do
      decision = described_class.new(node: node_a, score: 0.85, dimensions: { health: 1.0 }, rejected: [], degraded: false, policy: policy)
      h = decision.to_h
      expect(h[:placed]).to be true
      expect(h[:score]).to eq(0.85)
      expect(h[:node][:name]).to eq("node-a")
    end
  end

  # ── PlacementPlanner#place ────────────────────────────────────────────────────

  describe "#place" do
    subject(:planner) { described_class.new(observations) }

    it "returns a PlacementDecision" do
      decision = planner.place(:database)
      expect(decision).to be_a(Igniter::Cluster::Mesh::PlacementDecision)
    end

    it "selects a healthy node with matching capability" do
      decision = planner.place(:database)
      expect(decision.placed?).to be true
      expect(%w[node-a node-b]).to include(decision.name)
    end

    it "prefers the lower-load node when otherwise equal" do
      decision = planner.place(:database)
      # node-a has load_cpu 0.2 vs node-b 0.7 — node-a wins on load score
      expect(decision.name).to eq("node-a")
    end

    it "returns failed decision when no node has the capability" do
      decision = planner.place(:billing)
      expect(decision.failed?).to be true
      expect(decision.score).to be_nil
    end

    it "filters by multiple capabilities" do
      decision = planner.place(%i[database orders])
      expect(decision.placed?).to be true
      expect(decision.name).to eq("node-a")
    end

    it "places without capability constraint (nil)" do
      decision = planner.place(nil)
      expect(decision.placed?).to be true
    end

    it "includes rejected candidates in the decision" do
      decision = planner.place(:database)
      expect(decision.rejected).not_to be_empty
      expect(decision.rejected.all? { |r| r.key?(:name) && r.key?(:score) }).to be true
    end

    it "includes per-dimension breakdown" do
      decision = planner.place(:database)
      expect(decision.dimensions.keys).to include(:health, :trust, :load_cpu, :load_memory, :locality, :confidence, :freshness)
    end

    it "score is a Float in (0, 1]" do
      decision = planner.place(:database)
      expect(decision.score).to be_a(Float)
      expect(decision.score).to be > 0
      expect(decision.score).to be <= 1.0
    end

    context "with require_trust policy" do
      let(:policy) { Igniter::Cluster::Mesh::PlacementPolicy.new(require_trust: true) }
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "only selects trusted nodes" do
        decision = planner.place(:database)
        expect(decision.placed?).to be true
        expect(%w[node-a node-b]).to include(decision.name)
      end

      it "fails when only untrusted nodes have the capability" do
        decision = planner.place(:analytics)
        expect(decision.failed?).to be true
      end
    end

    context "with zone locality_preference" do
      let(:policy) do
        Igniter::Cluster::Mesh::PlacementPolicy.new(
          zone: "us-east-1a",
          locality_preference: :zone
        )
      end
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "selects only the node in the specified zone" do
        decision = planner.place(:database)
        expect(decision.name).to eq("node-a")
      end

      it "fails when no node in zone has the capability" do
        decision = planner.place(:analytics)
        expect(decision.failed?).to be true
      end
    end

    context "with region locality_preference" do
      let(:policy) do
        Igniter::Cluster::Mesh::PlacementPolicy.new(
          region: "us-east-1",
          locality_preference: :region
        )
      end
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "constrains candidates to the region" do
        decision = planner.place(:database)
        expect(%w[node-a node-b]).to include(decision.name)
      end
    end

    context "with max_load_cpu constraint" do
      let(:policy) { Igniter::Cluster::Mesh::PlacementPolicy.new(max_load_cpu: 0.5) }
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "excludes nodes above the threshold" do
        decision = planner.place(:database)
        expect(decision.name).to eq("node-a")
      end
    end

    context "with degraded_fallback" do
      let(:policy) do
        Igniter::Cluster::Mesh::PlacementPolicy.new(
          zone: "us-east-1a",
          locality_preference: :zone,
          require_trust: true,
          degraded_fallback: true
        )
      end
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "falls back to relaxed policy when primary set is empty" do
        # analytics only exists on node-c (eu zone, untrusted) — primary empty
        decision = planner.place(:analytics)
        expect(decision.placed?).to be true
        expect(decision.degraded?).to be true
        expect(decision.name).to eq("node-c")
      end

      it "does not mark degraded when primary set is non-empty" do
        decision = planner.place(:database)
        expect(decision.placed?).to be true
        expect(decision.degraded?).to be false
      end
    end

    context "with degraded_fallback disabled" do
      let(:policy) do
        Igniter::Cluster::Mesh::PlacementPolicy.new(
          zone: "us-east-1a",
          locality_preference: :zone,
          require_trust: true,
          degraded_fallback: false
        )
      end
      subject(:planner) { described_class.new(observations, policy: policy) }

      it "returns failed decision when primary set is empty" do
        decision = planner.place(:analytics)
        expect(decision.failed?).to be true
        expect(decision.degraded?).to be false
      end
    end

    it "includes workload dimension in per-dimension breakdown" do
      decision = planner.place(:database)
      expect(decision.dimensions.keys).to include(:workload)
    end

    context "with workload-enriched observations" do
      def make_workload_obs(name:, caps:, failure_rate:, degraded:, overloaded: false)
        Igniter::Cluster::Mesh::NodeObservation.new(
          name: name, url: "http://#{name}:4567",
          capabilities: caps, tags: [],
          metadata: {
            mesh: { observed_at: observed_at, confidence: 1.0, hops: 0 },
            mesh_state: { health: "healthy" },
            mesh_trust: { status: "trusted", trusted: true },
            mesh_workload: { failure_rate: failure_rate, total: 20, degraded: degraded, overloaded: overloaded }
          }
        )
      end

      it "prefers workload-healthy node over degraded node" do
        healthy_node  = make_workload_obs(name: "wl-healthy",  caps: [:api], failure_rate: 0.02, degraded: false)
        degraded_node = make_workload_obs(name: "wl-degraded", caps: [:api], failure_rate: 0.7,  degraded: true)
        decision = described_class.new([degraded_node, healthy_node]).place(:api)
        expect(decision.name).to eq("wl-healthy")
      end

      it "workload_score is 0.2 when degraded, 0.3 when overloaded, 0.0 when both" do
        degraded_obs  = make_workload_obs(name: "d",  caps: [:x], failure_rate: 0.8, degraded: true)
        overloaded_obs= make_workload_obs(name: "ol", caps: [:x], failure_rate: 0.1, degraded: false, overloaded: true)
        both_obs      = make_workload_obs(name: "b",  caps: [:x], failure_rate: 0.9, degraded: true,  overloaded: true)

        planner_wl = described_class.new([degraded_obs, overloaded_obs, both_obs])
        decision = planner_wl.place(:x)
        expect(decision.name).to eq("ol")
        expect(decision.dimensions[:workload]).to eq(0.3)
      end

      it "workload_score is 0.8 (neutral) when observation has no workload data" do
        plain_obs = make_obs(name: "plain", caps: [:svc], state: { health: "healthy" }, trust_status: :trusted)
        decision = described_class.new([plain_obs]).place(:svc)
        expect(decision.dimensions[:workload]).to eq(0.8)
      end
    end

    it "breaks ties by node name (stable ordering)" do
      twin_a = make_obs(name: "twin-a",
                        caps: %i[cache],
                        state: { health: "healthy", load_cpu: 0.5, load_memory: 0.5 },
                        trust_status: :trusted)
      twin_b = make_obs(name: "twin-b",
                        caps: %i[cache],
                        state: { health: "healthy", load_cpu: 0.5, load_memory: 0.5 },
                        trust_status: :trusted)
      planner = described_class.new([twin_b, twin_a])
      decision = planner.place(:cache)
      expect(decision.name).to eq("twin-a")
    end
  end
end
