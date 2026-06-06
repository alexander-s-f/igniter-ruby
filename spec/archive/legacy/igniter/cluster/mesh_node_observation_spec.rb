# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Mesh::NodeObservation do
  let(:now) { Time.utc(2026, 4, 18, 10, 0, 0) }
  let(:observed_at) { Time.utc(2026, 4, 18, 9, 59, 0).iso8601 }

  let(:base_metadata) do
    {
      mesh: {
        observed_at: observed_at,
        confidence: 1.0,
        hops: 0,
        origin: "node-a"
      }
    }
  end

  subject(:obs) do
    described_class.new(
      name:         "node-a",
      url:          "http://node-a:4567",
      capabilities: [:database, :orders],
      tags:         [:linux],
      metadata:     Igniter::Cluster::Mesh::PeerMetadata.runtime(base_metadata, now: now)
    )
  end

  # ── CapabilityQuery interface ─────────────────────────────────────────────────

  describe "CapabilityQuery interface" do
    it "implements capability?" do
      expect(obs.capability?(:database)).to be true
      expect(obs.capability?("orders")).to be true
      expect(obs.capability?(:billing)).to be false
    end

    it "implements tag?" do
      expect(obs.tag?(:linux)).to be true
      expect(obs.tag?(:darwin)).to be false
    end

    it "implements metadata" do
      expect(obs.metadata).to be_a(Hash)
      expect(obs.metadata[:mesh]).to include(observed_at: observed_at, confidence: 1.0)
    end

    it "is accepted by CapabilityQuery#matches_profile?" do
      query = Igniter::Cluster::Replication::CapabilityQuery.new(all_of: [:database])
      expect(query.matches_profile?(obs)).to be true

      query_miss = Igniter::Cluster::Replication::CapabilityQuery.new(all_of: [:billing])
      expect(query_miss.matches_profile?(obs)).to be false
    end

    it "matches via #matches_query?" do
      expect(obs.matches_query?(all_of: [:database], tags: [:linux])).to be true
      expect(obs.matches_query?(all_of: [:database], tags: [:darwin])).to be false
    end
  end

  # ── Provenance dimension ──────────────────────────────────────────────────────

  describe "provenance" do
    it "reads observed_at and observed_by from mesh envelope" do
      expect(obs.observed_at).to eq(observed_at)
      expect(obs.observed_by).to eq("node-a")
    end

    it "reads confidence and hops" do
      expect(obs.confidence).to eq(1.0)
      expect(obs.hops).to eq(0)
    end

    it "is authoritative when hops == 0" do
      expect(obs).to be_authoritative
    end

    it "is not authoritative when hops > 0" do
      relayed_meta = Igniter::Cluster::Mesh::PeerMetadata.relay(
        base_metadata,
        relayed_by: "node-b",
        observed_at: now
      )
      relayed = described_class.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [], tags: [],
        metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(relayed_meta, now: now)
      )
      expect(relayed).not_to be_authoritative
      expect(relayed.hops).to eq(1)
      expect(relayed.relayed_by).to eq("node-b")
    end

    it "freshness_seconds is available via metadata[:mesh]" do
      expect(obs.metadata[:mesh][:freshness_seconds]).to eq(60)
    end

    it "#fresh? is true when under threshold" do
      expect(obs.fresh?(max_seconds: 120)).to be true
    end

    it "#fresh? is false when over threshold" do
      expect(obs.fresh?(max_seconds: 30)).to be false
    end
  end

  # ── State dimension ───────────────────────────────────────────────────────────

  describe "state dimension" do
    let(:state_meta) do
      base_metadata.merge(
        mesh_state: { health: "healthy", load_cpu: 0.35, load_memory: 0.6, concurrency: 4, queue_depth: 2 }
      )
    end

    subject(:obs_with_state) do
      described_class.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [:database], tags: [],
        metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(state_meta, now: now)
      )
    end

    it "reads health" do
      expect(obs_with_state.health).to eq(:healthy)
    end

    it "reads load_cpu and load_memory" do
      expect(obs_with_state.load_cpu).to eq(0.35)
      expect(obs_with_state.load_memory).to eq(0.6)
    end

    it "reads concurrency and queue_depth" do
      expect(obs_with_state.concurrency).to eq(4)
      expect(obs_with_state.queue_depth).to eq(2)
    end

    it "defaults health to :unknown when mesh_state is absent" do
      expect(obs.health).to eq(:unknown)
    end

    it "defaults concurrency and queue_depth to 0" do
      expect(obs.concurrency).to eq(0)
      expect(obs.queue_depth).to eq(0)
    end

    it "is queryable by load via metadata path" do
      query = Igniter::Cluster::Replication::CapabilityQuery.new(
        all_of: [:database],
        metadata: { mesh_state: { load_cpu: { max: 0.5 } } }
      )
      expect(query.matches_profile?(obs_with_state)).to be true

      overloaded = described_class.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [:database], tags: [],
        metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(
          base_metadata.merge(mesh_state: { load_cpu: 0.9 }),
          now: now
        )
      )
      expect(query.matches_profile?(overloaded)).to be false
    end
  end

  # ── Locality dimension ────────────────────────────────────────────────────────

  describe "locality dimension" do
    let(:locality_meta) do
      base_metadata.merge(
        mesh_locality: { region: "us-east-1", zone: "us-east-1a", proximity_tags: ["rack-12"] }
      )
    end

    subject(:obs_with_locality) do
      described_class.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [], tags: [],
        metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(locality_meta, now: now)
      )
    end

    it "reads region and zone" do
      expect(obs_with_locality.region).to eq("us-east-1")
      expect(obs_with_locality.zone).to eq("us-east-1a")
    end

    it "reads proximity_tags as symbols" do
      expect(obs_with_locality.proximity_tags).to eq([:"rack-12"])
    end

    it "returns nil for absent locality" do
      expect(obs.region).to be_nil
      expect(obs.zone).to be_nil
      expect(obs.proximity_tags).to eq([])
    end

    it "is queryable by zone via metadata path" do
      query = Igniter::Cluster::Replication::CapabilityQuery.new(
        metadata: { mesh_locality: { zone: "us-east-1a" } }
      )
      expect(query.matches_profile?(obs_with_locality)).to be true
      expect(query.matches_profile?(obs)).to be false
    end
  end

  # ── Workload dimension ────────────────────────────────────────────────────────

  describe "workload dimension" do
    let(:workload_meta) do
      base_metadata.merge(
        mesh_workload: {
          failure_rate:    0.35,
          avg_duration_ms: 620.0,
          total:           40,
          degraded:        true,
          overloaded:      true
        }
      )
    end

    subject(:obs_with_workload) do
      described_class.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [:database], tags: [],
        metadata: Igniter::Cluster::Mesh::PeerMetadata.runtime(workload_meta, now: now)
      )
    end

    it "reads failure_rate" do
      expect(obs_with_workload.workload_failure_rate).to eq(0.35)
    end

    it "reads avg_duration_ms" do
      expect(obs_with_workload.workload_avg_duration_ms).to eq(620.0)
    end

    it "reads workload_total" do
      expect(obs_with_workload.workload_total).to eq(40)
    end

    it "workload_degraded? is true when flagged" do
      expect(obs_with_workload).to be_workload_degraded
    end

    it "workload_overloaded? is true when flagged" do
      expect(obs_with_workload).to be_workload_overloaded
    end

    it "workload_healthy? is false when degraded or overloaded" do
      expect(obs_with_workload).not_to be_workload_healthy
    end

    it "workload_observed? is true when mesh_workload key present" do
      expect(obs_with_workload).to be_workload_observed
    end

    it "workload_observed? is false when no workload data" do
      expect(obs).not_to be_workload_observed
    end

    it "workload_failure_rate returns nil when no workload data" do
      expect(obs.workload_failure_rate).to be_nil
    end

    it "workload_total defaults to 0 when no data" do
      expect(obs.workload_total).to eq(0)
    end

    it "workload_degraded? is false by default" do
      expect(obs).not_to be_workload_degraded
    end

    it "workload_healthy? is true when not degraded and not overloaded" do
      healthy = described_class.new(
        name: "n", url: "http://n", capabilities: [], tags: [],
        metadata: base_metadata.merge(
          mesh_workload: { failure_rate: 0.05, total: 20, degraded: false, overloaded: false }
        )
      )
      expect(healthy).to be_workload_healthy
    end

    it "WorkloadTracker#to_metadata_for populates mesh_workload via Peer#to_observation" do
      tracker = Igniter::Cluster::Mesh::WorkloadTracker.new(degraded_threshold: 0.3)
      5.times { tracker.record("node-a", :db, success: false, duration_ms: 900) }
      peer = Igniter::Cluster::Mesh::Peer.new(name: "node-a", url: "http://n", capabilities: [:db], tags: [])
      observation = peer.to_observation(now: now, workload_tracker: tracker)
      expect(observation).to be_workload_observed
      expect(observation).to be_workload_degraded
      expect(observation.workload_total).to eq(5)
    end
  end

  # ── OLAP Point summary ────────────────────────────────────────────────────────

  describe "#dimensions" do
    it "returns a hash covering all OLAP dimensions" do
      d = obs.dimensions
      expect(d.keys).to contain_exactly(:capabilities, :trust, :state, :locality, :governance, :provenance, :workload)
    end

    it "capabilities dimension includes values and provenance" do
      expect(obs.dimensions[:capabilities][:values]).to eq(%i[database orders])
    end

    it "provenance dimension includes confidence and hops" do
      expect(obs.dimensions[:provenance][:confidence]).to eq(1.0)
      expect(obs.dimensions[:provenance][:hops]).to eq(0)
      expect(obs.dimensions[:provenance][:authoritative]).to be true
    end

    it "is frozen" do
      expect(obs.dimensions).to be_frozen
    end
  end

  # ── Factory ───────────────────────────────────────────────────────────────────

  describe ".from_peer_hash" do
    let(:peer_hash) do
      {
        name: "node-a",
        url: "http://node-a:4567",
        capabilities: [:database],
        tags: [:linux],
        metadata: base_metadata
      }
    end

    it "builds a NodeObservation with freshness computed at the given time" do
      observation = described_class.from_peer_hash(peer_hash, now: now)
      expect(observation).to be_a(described_class)
      expect(observation.name).to eq("node-a")
      expect(observation.capability?(:database)).to be true
      expect(observation.metadata[:mesh][:freshness_seconds]).to eq(60)
    end

    it "round-trips via to_h" do
      observation = described_class.from_peer_hash(peer_hash, now: now)
      h = observation.to_h
      expect(h[:name]).to eq("node-a")
      expect(h[:capabilities]).to eq(%i[database])
    end
  end

  # ── Peer integration ──────────────────────────────────────────────────────────

  describe "Peer#to_observation" do
    let(:peer) do
      Igniter::Cluster::Mesh::Peer.new(
        name:         "node-a",
        url:          "http://node-a:4567",
        capabilities: [:database, :orders],
        tags:         [:linux],
        metadata:     base_metadata
      )
    end

    it "returns a NodeObservation" do
      expect(peer.to_observation(now: now)).to be_a(described_class)
    end

    it "Peer#profile returns a NodeObservation" do
      expect(peer.profile).to be_a(described_class)
    end

    it "the observation is accepted by CapabilityQuery" do
      query = Igniter::Cluster::Replication::CapabilityQuery.new(all_of: [:database])
      expect(query.matches_profile?(peer.to_observation(now: now))).to be true
    end
  end

  # ── Config integration ────────────────────────────────────────────────────────

  describe "Mesh::Config local_state and local_locality" do
    let(:config) { Igniter::Cluster::Mesh::Config.new }

    it "defaults to empty hashes" do
      expect(config.local_state).to eq({})
      expect(config.local_locality).to eq({})
    end

    it "accepts state and locality configuration" do
      config.local_state    = { health: :healthy, load_cpu: 0.2 }
      config.local_locality = { region: "eu-central-1", zone: "eu-central-1a" }

      expect(config.local_state[:health]).to eq(:healthy)
      expect(config.local_locality[:region]).to eq("eu-central-1")
    end
  end

  # ── PeerRegistry integration ──────────────────────────────────────────────────

  describe "PeerRegistry observation methods" do
    let(:registry) { Igniter::Cluster::Mesh::PeerRegistry.new }
    let(:peer) do
      Igniter::Cluster::Mesh::Peer.new(
        name: "node-a", url: "http://node-a:4567",
        capabilities: [:database], tags: [],
        metadata: base_metadata
      )
    end

    before { registry.register(peer) }

    it "#observation_for returns a NodeObservation" do
      obs = registry.observation_for("node-a", now: now)
      expect(obs).to be_a(described_class)
      expect(obs.name).to eq("node-a")
    end

    it "#observation_for returns nil for unknown peer" do
      expect(registry.observation_for("unknown", now: now)).to be_nil
    end

    it "#observations returns NodeObservation array" do
      result = registry.observations(now: now)
      expect(result).to all(be_a(described_class))
      expect(result.size).to eq(1)
    end

    it "#observations_matching_query filters by CapabilityQuery" do
      matched = registry.observations_matching_query({ all_of: [:database] }, now: now)
      expect(matched.size).to eq(1)

      no_match = registry.observations_matching_query({ all_of: [:billing] }, now: now)
      expect(no_match).to be_empty
    end
  end
end
