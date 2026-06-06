# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "tmpdir"

RSpec.describe "Igniter Cluster identity and trust" do
  let(:identity) { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "seed-node") }
  let(:manifest) do
    Igniter::Cluster::Identity::Manifest.build(
      identity: identity,
      peer_name: "seed-node",
      url: "http://seed:4567",
      capabilities: %i[mesh_seed notes_api],
      tags: %i[local seed],
      metadata: { region: "local" },
      contracts: ["SyncNotes"]
    )
  end

  it "builds a signed manifest that verifies with its own public key" do
    expect(manifest.verify_signature).to be(true)
    expect(manifest.capability_attestation).not_to be_nil
    expect(manifest.capability_attestation.verify_signature).to be(true)
    expect(manifest.identity_summary).to include(
      node_id: "seed-node",
      algorithm: "rsa-sha256",
      fingerprint: kind_of(String)
    )
  end

  it "builds a signed governance checkpoint that verifies with the trust store" do
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "seed-node", public_key: identity.public_key_pem, label: "bootstrap" }
      ]
    )
    trail = Igniter::Cluster::Governance::Trail.new
    trail.record(:routing_plan_applied, source: :spec, payload: { step: 1 })

    checkpoint = Igniter::Cluster::Governance::Checkpoint.build(
      identity: identity,
      peer_name: "seed-node",
      trail: trail,
      limit: 5
    )
    assessment = Igniter::Cluster::Trust::Verifier.assess_governance_checkpoint(
      checkpoint,
      trust_store: trust_store
    )

    expect(checkpoint.verify_signature).to be(true)
    expect(checkpoint.crest).to include(
      total: 1,
      latest_type: :routing_plan_applied,
      by_type: { routing_plan_applied: 1 }
    )
    expect(checkpoint.crest_digest).to be_a(String)
    expect(assessment.to_h).to include(
      status: :trusted,
      trusted: true,
      node_id: "seed-node",
      peer_name: "seed-node"
    )
  end

  it "assesses manifests as trusted when the trust store knows the public key" do
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "seed-node", public_key: identity.public_key_pem, label: "bootstrap" }
      ]
    )

    assessment = Igniter::Cluster::Trust::Verifier.assess(manifest, trust_store: trust_store)

    expect(assessment.to_h).to include(
      status: :trusted,
      trusted: true,
      node_id: "seed-node",
      peer_name: "seed-node"
    )
  end

  it "wraps relayed peer metadata with mesh_identity and mesh_trust summaries" do
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "seed-node", public_key: identity.public_key_pem, label: "bootstrap" }
      ]
    )

    envelope = Igniter::Cluster::Mesh::PeerIdentityEnvelope.build(
      source: manifest.to_h,
      trust_store: trust_store
    )

    expect(envelope).to include(
      name: "seed-node",
      url: "http://seed:4567",
      capabilities: %i[mesh_seed notes_api],
      tags: %i[local seed]
    )
    expect(envelope.dig(:metadata, :mesh_identity)).to include(
      node_id: "seed-node",
      peer_name: "seed-node",
      fingerprint: manifest.fingerprint
    )
    expect(envelope.dig(:metadata, :mesh_trust)).to include(
      status: :trusted,
      trusted: true
    )
    expect(envelope.dig(:metadata, :mesh_capabilities)).to include(
      node_id: "seed-node",
      observed_at: kind_of(String),
      capabilities: %i[mesh_seed notes_api],
      tags: %i[local seed]
    )
    expect(envelope.dig(:metadata, :mesh_capabilities, :trust)).to include(
      status: :trusted,
      trusted: true
    )
  end

  it "builds a trust admission plan for an unknown discovered peer and applies it after approval" do
    Igniter::Cluster::Mesh.reset!
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "seed-node", public_key: identity.public_key_pem, label: "bootstrap" }
      ]
    )

    discovered_identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "edge-node")
    discovered_manifest = Igniter::Cluster::Identity::Manifest.build(
      identity: discovered_identity,
      peer_name: "edge-node",
      url: "http://edge:4567",
      capabilities: [:speech_io],
      tags: [:edge],
      metadata: { region: "local" },
      contracts: []
    )

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
      c.trust_store = trust_store
      attributes = Igniter::Cluster::Mesh::PeerIdentityEnvelope.build(
        source: discovered_manifest.to_h,
        trust_store: trust_store
      )
      c.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(
          name: attributes[:name],
          url: attributes[:url],
          capabilities: attributes[:capabilities],
          tags: attributes[:tags],
          metadata: attributes[:metadata]
        )
      )
    end

    plan = Igniter::Cluster::Mesh.trust_admission_plan("edge-node", label: "lab-admitted")
    expect(plan.summary).to include(status: :pending_approval, peer_name: "edge-node", node_id: "edge-node")
    expect(plan.actions).to contain_exactly(
      include(
        action: :admit_trusted_peer,
        requires_approval: true,
        params: include(peer_name: "edge-node", node_id: "edge-node", label: "lab-admitted")
      )
    )

    blocked = Igniter::Cluster::Mesh.admit_trusted_peer!("edge-node")
    expect(blocked).to be_blocked
    expect(Igniter::Cluster::Mesh.config.trust_store.known?("edge-node")).to be(false)

    applied = Igniter::Cluster::Mesh.admit_trusted_peer!("edge-node", approve: true, label: "lab-admitted")
    expect(applied).to be_applied
    expect(Igniter::Cluster::Mesh.config.trust_store.known?("edge-node")).to be(true)
    expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("edge-node").metadata.dig(:mesh_trust, :status)).to eq(:trusted)
    expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("edge-node").metadata.dig(:mesh_capabilities, :trust, :status)).to eq(:trusted)
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "executes admit_trusted_peer routing plans through the mesh executor" do
    Igniter::Cluster::Mesh.reset!
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "seed-node", public_key: identity.public_key_pem, label: "bootstrap" }
      ]
    )

    discovered_identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "edge-node")
    discovered_manifest = Igniter::Cluster::Identity::Manifest.build(
      identity: discovered_identity,
      peer_name: "edge-node",
      url: "http://edge:4567",
      capabilities: [:speech_io],
      tags: [:edge],
      metadata: { region: "local" },
      contracts: []
    )

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
      c.trust_store = trust_store
      attributes = Igniter::Cluster::Mesh::PeerIdentityEnvelope.build(
        source: discovered_manifest.to_h,
        trust_store: trust_store
      )
      c.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(
          name: attributes[:name],
          url: attributes[:url],
          capabilities: attributes[:capabilities],
          tags: attributes[:tags],
          metadata: attributes[:metadata]
        )
      )
    end

    routing_plan = {
      action: :admit_trusted_peer,
      scope: :routing_trust,
      automated: false,
      requires_approval: true,
      params: {
        trust_keys: %i[identity attestation],
        peer_candidates: ["edge-node"]
      }
    }

    blocked = Igniter::Cluster::Mesh.execute_routing_plan!(routing_plan)
    expect(blocked).to be_blocked
    expect(blocked.summary).to include(status: :blocked)

    applied = Igniter::Cluster::Mesh.execute_routing_plan!(routing_plan, approve: true, label: "routing-admitted")
    expect(applied).to be_applied
    expect(applied.summary).to include(source_plan_action: :admit_trusted_peer, candidate_peer: "edge-node")
    expect(Igniter::Cluster::Mesh.config.trust_store.entry_for("edge-node").label).to eq("routing-admitted")
    expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("edge-node").metadata.dig(:mesh_trust, :status)).to eq(:trusted)
    expect(Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 10)).to include(
      total: 4,
      latest_type: :routing_plan_applied,
      by_type: include(
        trust_admission_blocked: 1,
        routing_plan_blocked: 1,
        trust_admission_applied: 1,
        routing_plan_applied: 1
      )
    )
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "executes governance checkpoint refresh routing plans through the mesh executor" do
    Igniter::Cluster::Mesh.reset!

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
      c.local_url = "http://seed:4567"
    end
    Igniter::Cluster::Mesh.config.governance_trail.record(
      :trust_admission_applied,
      source: :spec,
      payload: { peer_name: "edge-node" }
    )

    routing_plan = {
      action: :refresh_governance_checkpoint,
      scope: :mesh_governance,
      automated: true,
      requires_approval: false,
      params: {
        governance_keys: %i[trust latest_type],
        peer_candidates: ["edge-node"]
      }
    }

    applied = Igniter::Cluster::Mesh.execute_routing_plan!(routing_plan)
    expect(applied).to be_applied
    expect(applied.summary).to include(
      status: :applied,
      source_plan_action: :refresh_governance_checkpoint,
      announced_to: 0,
      checkpoint: include(
        node_id: "seed-node",
        peer_name: "seed-node",
        crest_digest: kind_of(String),
        latest_type: :trust_admission_applied,
        total: 1
      )
    )
    expect(applied.applied).to contain_exactly(
      include(
        action: :refresh_governance_checkpoint,
        status: :applied,
        scope: :mesh_governance,
        checkpoint: include(
          node_id: "seed-node",
          peer_name: "seed-node",
          crest_digest: kind_of(String)
        ),
        announced_to: 0
      )
    )
    expect(Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 10)).to include(
      total: 3,
      latest_type: :routing_plan_applied,
      by_type: include(
        trust_admission_applied: 1,
        governance_checkpoint_refreshed: 1,
        routing_plan_applied: 1
      )
    )
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "executes governance relaxation plans through the mesh executor with approval" do
    Igniter::Cluster::Mesh.reset!

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
    end

    routing_plan = {
      action: :relax_governance_requirements,
      scope: :routing_governance,
      automated: false,
      requires_approval: true,
      params: {
        governance_keys: %i[blocked_events latest_type],
        peer_candidates: ["orders-blocked"]
      }
    }

    blocked = Igniter::Cluster::Mesh.execute_routing_plan!(routing_plan)
    expect(blocked).to be_blocked
    expect(blocked.summary).to include(status: :blocked, reason: :approval_required)

    applied = Igniter::Cluster::Mesh.execute_routing_plan!(routing_plan, approve: true)
    expect(applied).to be_applied
    expect(applied.summary).to include(
      status: :applied,
      source_plan_action: :relax_governance_requirements,
      governance_keys: %i[blocked_events latest_type],
      peer_candidates: ["orders-blocked"],
      advisory_only: true
    )
    expect(applied.applied).to contain_exactly(
      include(
        action: :relax_governance_requirements,
        status: :applied,
        advisory_only: true,
        params: include(
          governance_keys: %i[blocked_events latest_type],
          peer_candidates: ["orders-blocked"]
        )
      )
    )
    expect(Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 10)).to include(
      total: 3,
      latest_type: :routing_plan_applied,
      by_type: include(
        routing_plan_blocked: 1,
        governance_requirements_relaxed: 1,
        routing_plan_applied: 1
      )
    )
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "executes only automated routing plans in batch self-heal mode" do
    Igniter::Cluster::Mesh.reset!

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
      c.local_url = "http://seed:4567"
    end
    allow_any_instance_of(Igniter::Server::Client).to receive(:health).and_return({ "status" => "ok" })

    plans = [
      {
        action: :refresh_peer_health,
        scope: :mesh_health,
        automated: true,
        requires_approval: false,
        params: {
          peer_name: "edge-node",
          selected_url: "http://edge:4567"
        }
      },
      {
        action: :relax_governance_requirements,
        scope: :routing_governance,
        automated: false,
        requires_approval: true,
        params: {
          governance_keys: %i[blocked_events latest_type],
          peer_candidates: ["edge-node"]
        }
      }
    ]

    result = Igniter::Cluster::Mesh.execute_routing_plans!(plans, automated_only: true)

    expect(result).to be_applied
    expect(result).to be_skipped
    expect(result.summary).to include(
      status: :applied,
      total: 2,
      applied: 1,
      blocked: 0,
      skipped: 1,
      automated_only: true
    )
    expect(result.applied).to contain_exactly(
      include(
        action: :refresh_peer_health,
        status: :applied,
        peer_name: "edge-node",
        selected_url: "http://edge:4567",
        reachable: true
      )
    )
    expect(result.skipped).to contain_exactly(
      include(
        action: :relax_governance_requirements,
        reason: :manual_plan
      )
    )
    expect(Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 10)).to include(
      total: 2,
      latest_type: :routing_plan_applied,
      by_type: include(
        peer_health_refreshed: 1,
        routing_plan_applied: 1
      )
    )
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "self-heals directly from reported routing plans" do
    Igniter::Cluster::Mesh.reset!

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "seed-node"
      c.identity = identity
      c.local_url = "http://seed:4567"
    end
    Igniter::Cluster::Mesh.config.governance_trail.record(
      :trust_admission_applied,
      source: :spec,
      payload: { peer_name: "edge-node" }
    )

    report = {
      routing: {
        plans: [
          {
            action: :refresh_governance_checkpoint,
            scope: :mesh_governance,
            automated: true,
            requires_approval: false,
            params: {
              governance_keys: %i[trust latest_type],
              peer_candidates: ["edge-node"]
            }
          },
          {
            action: :relax_governance_requirements,
            scope: :routing_governance,
            automated: false,
            requires_approval: true,
            params: {
              governance_keys: %i[blocked_events latest_type],
              peer_candidates: ["edge-node"]
            }
          }
        ]
      }
    }

    result = Igniter::Cluster::Mesh.self_heal_routing!(report)

    expect(result).to be_applied
    expect(result).to be_skipped
    expect(result.summary).to include(
      status: :applied,
      total: 2,
      applied: 1,
      blocked: 0,
      skipped: 1,
      automated_only: true
    )
    expect(result.applied).to contain_exactly(
      include(
        action: :refresh_governance_checkpoint,
        status: :applied,
        checkpoint: include(
          node_id: "seed-node",
          peer_name: "seed-node",
          crest_digest: kind_of(String)
        )
      )
    )
    expect(result.skipped).to contain_exactly(
      include(
        action: :relax_governance_requirements,
        reason: :manual_plan
      )
    )
    expect(Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 10)).to include(
      total: 3,
      latest_type: :routing_plan_applied,
      by_type: include(
        trust_admission_applied: 1,
        governance_checkpoint_refreshed: 1,
        routing_plan_applied: 1
      )
    )
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "persists and reloads the cluster governance crest with retention" do
    Igniter::Cluster::Mesh.reset!

    Dir.mktmpdir do |dir|
      path = File.join(dir, "cluster/governance.jsonl")
      archive_path = File.join(dir, "cluster/governance.archive.jsonl")

      Igniter::Cluster::Mesh.configure do |c|
        c.governance_log(
          path,
          archive: archive_path,
          retain_events: 3,
          retention_policy: {
            blocked: 1,
            applied: 1,
            default: 1
          }
        )
      end

      trail = Igniter::Cluster::Mesh.config.governance_trail
      trail.record(:routing_plan_blocked, source: :spec, payload: { step: 1 })
      trail.record(:routing_plan_blocked, source: :spec, payload: { step: 2 })
      trail.record(:trust_admission_applied, source: :spec, payload: { step: 3 })
      trail.record(:routing_plan_applied, source: :spec, payload: { step: 4 })
      trail.record(:governance_tick, source: :spec, payload: { step: 5 })
      trail.record(:governance_tick, source: :spec, payload: { step: 6 })

      snapshot = trail.snapshot(limit: 10)
      expect(snapshot).to include(
        total: 3,
        latest_type: :governance_tick,
        by_type: {
          routing_plan_blocked: 1,
          routing_plan_applied: 1,
          governance_tick: 1
        },
        persistence: include(
          enabled: true,
          path: path,
          max_events: 3,
          archive_path: archive_path,
          archived_events: 3,
          retention_policy: {
            blocked: 1,
            applied: 1,
            default: 1
          },
          retained_by_class: {
            blocked: 1,
            applied: 1,
            other: 1
          }
        )
      )
      expect(snapshot[:events].map { |event| event.dig(:payload, :step) }).to eq([2, 4, 6])

      reloaded = Igniter::Cluster::Mesh.config.reload_governance_trail!
      expect(reloaded.snapshot(limit: 10)).to include(
        total: 3,
        latest_type: :governance_tick,
        persistence: include(
          path: path,
          archived_events: 3
        )
      )
      expect(reloaded.snapshot(limit: 10)[:events].map { |event| event.dig(:payload, :step) }).to eq([2, 4, 6])
    end
  ensure
    Igniter::Cluster::Mesh.reset!
  end
end
