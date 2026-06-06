# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Mesh::RebalancePlanner do
  let(:now)         { Time.utc(2026, 4, 18, 12, 0, 0) }
  let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 30).iso8601 }

  def make_obs(name:, caps: [], state: { health: "healthy" }, trust_status: :trusted)
    meta = { mesh: { observed_at: observed_at, confidence: 1.0, hops: 0, origin: name } }
    meta[:mesh_state] = state
    meta[:mesh_trust] = { status: trust_status.to_s, trusted: trust_status == :trusted }

    Igniter::Cluster::Mesh::NodeObservation.new(
      name:         name,
      url:          "http://#{name}:4567",
      capabilities: caps,
      tags:         [],
      metadata:     Igniter::Cluster::Mesh::PeerMetadata.runtime(meta, now: now)
    )
  end

  def make_claim(entity_type, entity_id, owner)
    Igniter::Cluster::Ownership::Claim.new(
      entity_type: entity_type,
      entity_id:   entity_id,
      owner:       owner
    )
  end

  def make_registry(*claims)
    registry = Igniter::Cluster::Ownership::Registry.new
    claims.each { |c| registry.claim(c.entity_type, c.entity_id, owner: c.owner) }
    registry
  end

  let(:node_a) { make_obs(name: "node-a", caps: %i[worker]) }
  let(:node_b) { make_obs(name: "node-b", caps: %i[worker]) }
  let(:node_c) { make_obs(name: "node-c", caps: %i[worker]) }

  let(:healthy_observations) { [node_a, node_b, node_c] }

  # ── RebalancePlan ─────────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::RebalancePlan do
    it "balanced? is true when no transfers" do
      plan = described_class.new(transfers: [], rationale: "ok", skew: 0)
      expect(plan.balanced?).to be true
    end

    it "balanced? is false when transfers are present" do
      t = { action: :transfer_ownership, entity_type: "job", entity_id: "1", from_owner: "a", to_owner: "b" }
      plan = described_class.new(transfers: [t], rationale: "skew", skew: 3)
      expect(plan.balanced?).to be false
      expect(plan.size).to eq(1)
    end

    it "to_routing_plans wraps transfers in routing plan hashes" do
      t = { action: :transfer_ownership, entity_type: "job", entity_id: "1", from_owner: "a", to_owner: "b" }
      plan = described_class.new(transfers: [t], rationale: "skew", skew: 3)
      rp = plan.to_routing_plans
      expect(rp.size).to eq(1)
      expect(rp.first[:action]).to eq(:transfer_ownership)
      expect(rp.first[:scope]).to eq(:ownership_placement)
      expect(rp.first[:params][:entity_type]).to eq("job")
      expect(rp.first[:params][:from_owner]).to eq("a")
      expect(rp.first[:params][:to_owner]).to eq("b")
    end

    it "to_h includes all fields" do
      plan = described_class.new(transfers: [], rationale: "balanced", skew: 1)
      h = plan.to_h
      expect(h.keys).to include(:transfers, :rationale, :skew)
    end
  end

  # ── RebalancePlanner#plan ─────────────────────────────────────────────────────

  describe "#plan" do
    subject(:planner) do
      described_class.new(
        ownership_registry: registry,
        observations:       healthy_observations
      )
    end

    context "when no claims exist" do
      let(:registry) { make_registry }

      it "returns balanced plan with no transfers" do
        plan = planner.plan
        expect(plan.balanced?).to be true
        expect(plan.rationale).to include("no claims")
      end
    end

    context "when no eligible nodes exist" do
      let(:registry) { make_registry(make_claim("job", "1", "node-a")) }

      it "returns empty plan with explanation" do
        unhealthy = make_obs(name: "sick", caps: %i[worker], state: { health: "degraded" })
        p = described_class.new(ownership_registry: registry, observations: [unhealthy])
        plan = p.plan
        expect(plan.balanced?).to be true
        expect(plan.rationale).to include("no eligible nodes")
      end
    end

    context "when distribution is already balanced" do
      let(:registry) do
        make_registry(
          make_claim("job", "1", "node-a"),
          make_claim("job", "2", "node-b"),
          make_claim("job", "3", "node-c")
        )
      end

      it "returns balanced plan (skew = 0, within threshold 2)" do
        plan = planner.plan
        expect(plan.balanced?).to be true
        expect(plan.skew).to eq(0)
      end
    end

    context "when skew is 2 (within default threshold)" do
      let(:registry) do
        make_registry(
          make_claim("job", "1", "node-a"),
          make_claim("job", "2", "node-a"),
          make_claim("job", "3", "node-b"),
          make_claim("job", "4", "node-c"),
          make_claim("job", "5", "node-c")
        )
        # counts: a=2, b=1, c=2 — skew = 1 ≤ 2
      end

      it "does not generate transfers" do
        plan = planner.plan
        expect(plan.balanced?).to be true
      end
    end

    context "when skew exceeds threshold" do
      let(:registry) do
        make_registry(
          make_claim("job", "1", "node-a"),
          make_claim("job", "2", "node-a"),
          make_claim("job", "3", "node-a"),
          make_claim("job", "4", "node-a"),
          make_claim("job", "5", "node-b")
          # counts: a=4, b=1, c=0 — skew = 4
        )
      end

      it "returns a plan with transfers" do
        plan = planner.plan
        expect(plan.balanced?).to be false
        expect(plan.size).to be > 0
      end

      it "transfers from overloaded to underloaded node" do
        plan = planner.plan
        expect(plan.transfers.all? { |t| t[:action] == :transfer_ownership }).to be true
        expect(plan.transfers.any? { |t| t[:from_owner] == "node-a" }).to be true
        expect(plan.transfers.any? { |t| t[:to_owner] == "node-c" }).to be true
      end

      it "includes entity_type and entity_id in each transfer" do
        plan = planner.plan
        plan.transfers.each do |t|
          expect(t[:entity_type]).to eq("job")
          expect(t[:entity_id]).not_to be_nil
        end
      end

      it "records the detected skew" do
        plan = planner.plan
        expect(plan.skew).to eq(4)
      end

      it "includes rationale" do
        plan = planner.plan
        expect(plan.rationale).to include("skew 4")
        expect(plan.rationale).to include("transfer")
      end
    end

    context "with custom skew_threshold" do
      let(:registry) do
        make_registry(
          make_claim("job", "1", "node-a"),
          make_claim("job", "2", "node-a"),
          make_claim("job", "3", "node-b")
          # skew = 1
        )
      end

      it "triggers rebalancing when skew exceeds lower threshold" do
        p = described_class.new(ownership_registry: registry, observations: healthy_observations, skew_threshold: 0)
        plan = p.plan
        expect(plan.balanced?).to be false
        expect(plan.size).to be > 0
      end
    end

    context "when some claims are owned by ineligible nodes (orphaned)" do
      let(:unhealthy_obs) { make_obs(name: "node-x", caps: %i[worker], state: { health: "degraded" }) }
      let(:all_observations) { [node_a, node_b, node_c, unhealthy_obs] }
      let(:registry) do
        make_registry(
          make_claim("job", "1", "node-x"),
          make_claim("job", "2", "node-x"),
          make_claim("job", "3", "node-x"),
          make_claim("job", "4", "node-a")
        )
      end
      subject(:planner) do
        described_class.new(ownership_registry: registry, observations: all_observations)
      end

      it "transfers orphaned claims to eligible nodes" do
        plan = planner.plan
        expect(plan.balanced?).to be false
        expect(plan.transfers.any? { |t| t[:from_owner] == "node-x" }).to be true
        expect(plan.transfers.all? { |t| %w[node-a node-b node-c].include?(t[:to_owner]) }).to be true
      end
    end

    context "with capability filter" do
      let(:db_node_1) { make_obs(name: "db-1", caps: %i[database]) }
      let(:db_node_2) { make_obs(name: "db-2", caps: %i[database]) }
      let(:all_obs)   { healthy_observations + [db_node_1, db_node_2] }

      let(:registry) do
        # db-1 carries 4 shards, db-2 carries 1 — skew = 3 > threshold 1
        make_registry(
          make_claim("shard", "1", "db-1"),
          make_claim("shard", "2", "db-1"),
          make_claim("shard", "3", "db-1"),
          make_claim("shard", "4", "db-1"),
          make_claim("shard", "5", "db-2")
        )
      end

      it "only transfers between nodes that have the specified capability" do
        p = described_class.new(
          ownership_registry: registry,
          observations:       all_obs,
          capabilities:       [:database],
          skew_threshold:     1
        )
        plan = p.plan
        expect(plan.balanced?).to be false
        # worker nodes (node-a/b/c) must never appear as destinations
        expect(plan.transfers.map { |t| t[:to_owner] }.uniq).to all(match(/^db-/))
        expect(plan.transfers.map { |t| t[:from_owner] }.uniq).to all(match(/^db-/))
      end

      it "returns balanced when only one capable node exists" do
        single_registry = make_registry(
          make_claim("shard", "1", "db-1"),
          make_claim("shard", "2", "db-1"),
          make_claim("shard", "3", "db-1")
        )
        p = described_class.new(
          ownership_registry: single_registry,
          observations:       [db_node_1],
          capabilities:       [:database]
        )
        plan = p.plan
        expect(plan.balanced?).to be true
      end
    end
  end
end

# ── RoutingPlanExecutor :transfer_ownership integration ───────────────────────

RSpec.describe Igniter::Cluster::RoutingPlanExecutor, ":transfer_ownership" do
  def make_registry(*claims)
    registry = Igniter::Cluster::Ownership::Registry.new
    claims.each { |c| registry.claim(c[:entity_type], c[:entity_id], owner: c[:owner]) }
    registry
  end

  let(:registry) do
    make_registry(
      { entity_type: "job", entity_id: "1", owner: "node-a" },
      { entity_type: "job", entity_id: "2", owner: "node-a" }
    )
  end

  let(:config) do
    cfg = Igniter::Cluster::Mesh::Config.new
    cfg.ownership_registry = registry
    cfg
  end

  subject(:executor) { described_class.new(config: config) }

  let(:valid_plan) do
    {
      action:            :transfer_ownership,
      scope:             :ownership_placement,
      automated:         true,
      requires_approval: false,
      params: {
        entity_type: "job",
        entity_id:   "1",
        from_owner:  "node-a",
        to_owner:    "node-b"
      }
    }
  end

  it "transfers the claim to the new owner" do
    executor.run(valid_plan)
    expect(registry.owner_for("job", "1")).to eq("node-b")
  end

  it "returns an applied RoutingPlanResult" do
    result = executor.run(valid_plan)
    expect(result.applied?).to be true
    expect(result.applied.first[:to_owner]).to eq("node-b")
    expect(result.applied.first[:from_owner]).to eq("node-a")
  end

  it "records governance trail event" do
    executor.run(valid_plan)
    types = config.governance_trail.events.map { |e| e[:type] }
    expect(types).to include(:ownership_transferred, :routing_plan_applied)
  end

  it "blocks when no ownership_registry configured" do
    config.ownership_registry = nil
    result = executor.run(valid_plan)
    expect(result.blocked?).to be true
    expect(result.blocked.first[:reason]).to eq(:no_ownership_registry)
  end

  it "blocks when claim does not exist" do
    plan = valid_plan.dup
    plan[:params] = valid_plan[:params].merge(entity_id: "999")
    result = executor.run(plan)
    expect(result.blocked?).to be true
    expect(result.blocked.first[:reason]).to eq(:claim_not_found)
  end

  it "blocks when from_owner does not match actual owner" do
    plan = valid_plan.dup
    plan[:params] = valid_plan[:params].merge(from_owner: "node-x")
    result = executor.run(plan)
    expect(result.blocked?).to be true
    expect(result.blocked.first[:reason]).to eq(:owner_mismatch)
  end

  it "does not mutate other claims" do
    executor.run(valid_plan)
    expect(registry.owner_for("job", "2")).to eq("node-a")
  end

  context "via run_many (RebalancePlan#to_routing_plans integration)" do
    let(:now)         { Time.utc(2026, 4, 18, 12, 0, 0) }
    let(:observed_at) { Time.utc(2026, 4, 18, 11, 59, 30).iso8601 }

    def make_obs(name)
      meta = { mesh: { observed_at: observed_at, confidence: 1.0, hops: 0, origin: name },
               mesh_state: { health: "healthy" } }
      Igniter::Cluster::Mesh::NodeObservation.new(
        name:         name,
        url:          "http://#{name}:4567",
        capabilities: [:worker],
        tags:         [],
        metadata:     Igniter::Cluster::Mesh::PeerMetadata.runtime(meta, now: now)
      )
    end

    let(:node_a_obs) { make_obs("node-a") }
    let(:node_b_obs) { make_obs("node-b") }

    let(:unbalanced_registry) do
      make_registry(
        { entity_type: "job", entity_id: "1", owner: "node-a" },
        { entity_type: "job", entity_id: "2", owner: "node-a" },
        { entity_type: "job", entity_id: "3", owner: "node-a" },
        { entity_type: "job", entity_id: "4", owner: "node-b" }
      )
    end

    it "executes all transfer plans from RebalancePlanner end-to-end" do
      plan = Igniter::Cluster::Mesh::RebalancePlanner.new(
        ownership_registry: unbalanced_registry,
        observations:       [node_a_obs, node_b_obs],
        skew_threshold:     0
      ).plan

      cfg = Igniter::Cluster::Mesh::Config.new
      cfg.ownership_registry = unbalanced_registry

      result = described_class.new(config: cfg).run_many(plan.to_routing_plans)
      expect(result.applied?).to be true

      counts = Hash.new(0)
      unbalanced_registry.all.each { |c| counts[c.owner] += 1 }
      expect(counts.values.max - counts.values.min).to be <= 1
    end
  end
end
