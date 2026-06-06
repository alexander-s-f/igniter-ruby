# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter Mesh — Phase 2: Dynamic Discovery" do
  after { Igniter::Cluster::Mesh.reset! }

  # ─────────────────────────────────────────────────────────────────────────────
  # PeerRegistry
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::PeerRegistry do
    subject(:registry) { described_class.new }

    let(:peer_a) { Igniter::Cluster::Mesh::Peer.new(name: "orders", url: "http://orders:4567", capabilities: [:orders], tags: [:linux]) }
    let(:peer_b) { Igniter::Cluster::Mesh::Peer.new(name: "audit",  url: "http://audit:4567",  capabilities: [:audit], tags: [:linux]) }

    it "starts empty" do
      expect(registry.all).to be_empty
      expect(registry.size).to eq(0)
    end

    it "registers a peer" do
      registry.register(peer_a)
      expect(registry.all).to contain_exactly(peer_a)
      expect(registry.size).to eq(1)
    end

    it "register is idempotent — latest version wins" do
      registry.register(peer_a)
      updated = Igniter::Cluster::Mesh::Peer.new(name: "orders", url: "http://orders-v2:4567", capabilities: [:orders])
      registry.register(updated)
      expect(registry.size).to eq(1)
      expect(registry.peer_named("orders").url).to eq("http://orders-v2:4567")
    end

    it "unregisters a peer by name" do
      registry.register(peer_a)
      registry.unregister("orders")
      expect(registry.all).to be_empty
    end

    it "unregister is a no-op for unknown peers" do
      expect { registry.unregister("ghost") }.not_to raise_error
    end

    it "peers_with_capability filters correctly" do
      registry.register(peer_a)
      registry.register(peer_b)
      expect(registry.peers_with_capability(:orders)).to contain_exactly(peer_a)
      expect(registry.peers_with_capability(:audit)).to contain_exactly(peer_b)
      expect(registry.peers_with_capability(:unknown)).to be_empty
    end

    it "peers_matching_query filters correctly" do
      registry.register(peer_a)
      registry.register(peer_b)
      expect(registry.peers_matching_query(all_of: [:orders], tags: [:linux])).to contain_exactly(peer_a)
    end

    it "peer_named finds by name" do
      registry.register(peer_a)
      expect(registry.peer_named("orders")).to eq(peer_a)
      expect(registry.peer_named("missing")).to be_nil
    end

    it "peer_named coerces string/symbol" do
      registry.register(peer_a)
      expect(registry.peer_named("orders")).to eq(peer_a)
    end

    it "clear removes all peers" do
      registry.register(peer_a)
      registry.register(peer_b)
      registry.clear
      expect(registry.all).to be_empty
    end

    it "all returns a snapshot (not the live hash)" do
      snapshot = registry.all
      registry.register(peer_a)
      expect(snapshot).to be_empty
    end

    it "is thread-safe under concurrent writes" do
      threads = 50.times.map do |i|
        Thread.new do
          p = Igniter::Cluster::Mesh::Peer.new(name: "peer-#{i}", url: "http://p#{i}:4567")
          registry.register(p)
        end
      end
      threads.each(&:join)
      expect(registry.size).to eq(50)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Config — new Phase 2 attrs
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Config do
    subject(:config) { described_class.new }

    it "defaults seeds to []" do
      expect(config.seeds).to eq([])
    end

    it "defaults discovery_interval to 30" do
      expect(config.discovery_interval).to eq(30)
    end

    it "defaults auto_announce to true" do
      expect(config.auto_announce).to be true
    end

    it "defaults local_url to nil" do
      expect(config.local_url).to be_nil
    end

    it "has a PeerRegistry by default" do
      expect(config.peer_registry).to be_a(Igniter::Cluster::Mesh::PeerRegistry)
    end

    it "defaults auto_self_heal to false" do
      expect(config.auto_self_heal).to be false
    end

    it "defaults self_heal_interval to 15" do
      expect(config.self_heal_interval).to eq(15)
    end

    it "allows configuring seeds" do
      config.seeds = %w[http://seed1:4567 http://seed2:4567]
      expect(config.seeds).to eq(%w[http://seed1:4567 http://seed2:4567])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Announcer
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Announcer do
    let(:config) do
      Igniter::Cluster::Mesh::Config.new.tap do |c|
        c.peer_name          = "api-node"
        c.local_url          = "http://api.internal:4567"
        c.local_capabilities = %i[api]
        c.local_tags         = %i[linux]
        c.local_metadata     = { zone: "eu-1" }
        c.seeds              = %w[http://seed1:4567 http://seed2:4567]
      end
    end
    subject(:announcer) { described_class.new(config) }

    it "POSTs self to every seed on announce_all" do
      client_double = instance_double(Igniter::Server::Client)
      allow(client_double).to receive(:register_peer)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)

      announcer.announce_all

      expect(Igniter::Server::Client).to have_received(:new).with("http://seed1:4567", timeout: 5)
      expect(Igniter::Server::Client).to have_received(:new).with("http://seed2:4567", timeout: 5)
      expect(client_double).to have_received(:register_peer).twice.with(
        manifest: an_object_having_attributes(
          peer_name: "api-node",
          node_id: "api-node",
          url: "http://api.internal:4567",
          capabilities: %i[api],
          tags: %i[linux],
          metadata: hash_including(
            zone: "eu-1",
            mesh: hash_including(
              confidence: 1.0,
              hops: 0,
              origin: "api-node",
              observed_at: kind_of(String)
            ),
            mesh_governance: hash_including(
              node_id: "api-node",
              checkpointed_at: kind_of(String),
              crest_digest: kind_of(String),
              checkpoint: hash_including(
                node_id: "api-node",
                crest: hash_including(total: 0)
              )
            )
          ),
          signature: kind_of(String)
        )
      )
    end

    it "swallows ConnectionError on announce" do
      allow(Igniter::Server::Client).to receive(:new)
        .and_raise(Igniter::Server::Client::ConnectionError, "refused")

      expect { announcer.announce_all }.not_to raise_error
    end

    it "is a no-op when peer_name is not set" do
      config.peer_name = nil
      expect(Igniter::Server::Client).not_to receive(:new)
      announcer.announce_all
    end

    it "is a no-op when local_url is not set" do
      config.local_url = nil
      expect(Igniter::Server::Client).not_to receive(:new)
      announcer.announce_all
    end

    it "DELETEs self from every seed on deannounce_all" do
      client_double = instance_double(Igniter::Server::Client)
      allow(client_double).to receive(:unregister_peer)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)

      announcer.deannounce_all

      expect(client_double).to have_received(:unregister_peer).twice.with("api-node")
    end

    it "swallows ConnectionError on deannounce" do
      allow(Igniter::Server::Client).to receive(:new)
        .and_raise(Igniter::Server::Client::ConnectionError, "refused")

      expect { announcer.deannounce_all }.not_to raise_error
    end

    it "deannounce is a no-op when peer_name is not set" do
      config.peer_name = nil
      expect(Igniter::Server::Client).not_to receive(:new)
      announcer.deannounce_all
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Poller
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Poller do
    let(:config) do
      Igniter::Cluster::Mesh::Config.new.tap do |c|
        c.peer_name          = "api-node"
        c.seeds              = %w[http://seed1:4567]
        c.discovery_interval = 0.05
      end
    end
    subject(:poller) { described_class.new(config) }

    after { poller.stop }

    it "starts not running" do
      expect(poller).not_to be_running
    end

    it "start/stop changes running state" do
      poller.start
      expect(poller).to be_running
      poller.stop
      expect(poller).not_to be_running
    end

    it "start is idempotent" do
      poller.start
      thread_before = poller.instance_variable_get(:@thread)
      poller.start
      expect(poller.instance_variable_get(:@thread)).to be(thread_before)
    end

    it "poll_once registers peers from seeds (excluding self)" do
      client_double = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:list_peers).and_return([
        { name: "orders-node", url: "http://orders:4567", capabilities: [:orders] },
        { name: "api-node",    url: "http://api:4567",    capabilities: [:api] }  # self — skipped
      ])

      poller.poll_once

      expect(config.peer_registry.peer_named("orders-node")).not_to be_nil
      expect(config.peer_registry.peer_named("api-node")).to be_nil
    end

    it "poll_once adds relay confidence and hop metadata" do
      config.gossip_fanout = 0
      client_double = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:list_peers).and_return([
        {
          name: "orders-node",
          url: "http://orders:4567",
          capabilities: [:orders],
          metadata: {
            mesh: {
              observed_at: "2026-04-16T11:59:00Z",
              confidence: 1.0,
              hops: 0,
              origin: "orders-node"
            }
          }
        }
      ])

      poller.poll_once

      mesh = config.peer_registry.peer_named("orders-node").metadata[:mesh]
      expect(mesh).to include(
        observed_at: "2026-04-16T11:59:00Z",
        confidence: 0.9,
        hops: 1,
        origin: "orders-node",
        relayed_by: "http://seed1:4567"
      )
    end

    it "poll_once preserves signed governance checkpoints from seed peers" do
      config.gossip_fanout = 0
      identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "orders-node")
      trail = Igniter::Cluster::Governance::Trail.new
      trail.record(:routing_plan_applied, source: :spec, payload: { step: 1 })
      checkpoint = Igniter::Cluster::Governance::Checkpoint.build(
        identity: identity,
        peer_name: "orders-node",
        trail: trail
      )

      client_double = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:list_peers).and_return([
        {
          name: "orders-node",
          url: "http://orders:4567",
          capabilities: [:orders],
          metadata: {
            mesh_governance: {
              checkpointed_at: checkpoint.checkpointed_at,
              crest_digest: checkpoint.crest_digest,
              checkpoint: checkpoint.to_h
            }
          }
        }
      ])

      poller.poll_once

      governance = config.peer_registry.peer_named("orders-node").metadata[:mesh_governance]
      expect(governance).to include(
        node_id: "orders-node",
        checkpointed_at: checkpoint.checkpointed_at,
        crest_digest: checkpoint.crest_digest,
        checkpoint: hash_including(node_id: "orders-node"),
        trust: include(status: :unknown, trusted: false)
      )
    end

    it "poll_once swallows ConnectionError" do
      allow(Igniter::Server::Client).to receive(:new)
        .and_raise(Igniter::Server::Client::ConnectionError, "refused")

      expect { poller.poll_once }.not_to raise_error
    end

    it "poll_once skips peers with nil name or url" do
      client_double = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:list_peers).and_return([
        { name: nil, url: "http://x:4567", capabilities: [] },
        { name: "ok", url: nil,            capabilities: [] }
      ])

      poller.poll_once

      expect(config.peer_registry.all).to be_empty
    end

    it "background thread calls poll_once periodically" do
      call_count = 0
      allow(poller).to receive(:poll_once) { call_count += 1 }

      poller.start
      sleep(0.25)
      poller.stop

      expect(call_count).to be >= 2
    end

    context "checkpoint gossip (Poller)" do
      let(:remote_identity) { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "orders-node") }
      let(:remote_trail) do
        Igniter::Cluster::Governance::Trail.new.tap do |t|
          t.record(:routing_plan_applied, source: :spec, payload: {})
        end
      end
      let(:remote_checkpoint) do
        Igniter::Cluster::Governance::Checkpoint.build(
          identity: remote_identity, peer_name: "orders-node", trail: remote_trail
        )
      end
      let(:checkpoint_store) do
        Igniter::Cluster::Governance::Stores::CheckpointStore.new(
          path: File.join(Dir.tmpdir, "igniter_test_cp_poller_#{Process.pid}.json")
        )
      end

      before do
        config.gossip_fanout  = 0
        config.checkpoint_store = checkpoint_store
      end
      after { checkpoint_store.clear! }

      def stub_seed_with_checkpoint(cp)
        client_double = instance_double(Igniter::Server::Client)
        allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
        allow(client_double).to receive(:list_peers).and_return([
          {
            name: "orders-node",
            url: "http://orders:4567",
            capabilities: [:orders],
            metadata: {
              mesh_governance: {
                peer_name:       cp.peer_name,
                checkpointed_at: cp.checkpointed_at,
                crest_digest:    cp.crest_digest,
                checkpoint:      cp.to_h
              }
            }
          }
        ])
      end

      it "saves a newer remote checkpoint to the local store" do
        stub_seed_with_checkpoint(remote_checkpoint)

        poller.poll_once

        saved = checkpoint_store.load
        expect(saved).not_to be_nil
        expect(saved.crest_digest).to eq(remote_checkpoint.crest_digest)
      end

      it "records :checkpoint_replicated in the governance trail" do
        stub_seed_with_checkpoint(remote_checkpoint)

        poller.poll_once

        snap = config.governance_trail.snapshot(limit: 10)
        expect(snap[:by_type]).to include(checkpoint_replicated: 1)
      end

      it "does not overwrite a local checkpoint that is equally or more recent" do
        local_identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "local")
        local_trail = Igniter::Cluster::Governance::Trail.new
        # Build local checkpoint with a timestamp strictly after the remote one
        future_ts = (Time.parse(remote_checkpoint.checkpointed_at) + 60).utc.iso8601
        local_cp  = Igniter::Cluster::Governance::Checkpoint.build(
          identity: local_identity, peer_name: "local", trail: local_trail,
          checkpointed_at: future_ts
        )
        checkpoint_store.save(local_cp)

        stub_seed_with_checkpoint(remote_checkpoint)
        poller.poll_once

        saved = checkpoint_store.load
        expect(saved.crest_digest).to eq(local_cp.crest_digest)
      end

      it "does not save a checkpoint with an invalid signature" do
        tampered = remote_checkpoint.to_h.merge(crest: { total: 999 })
        client_double = instance_double(Igniter::Server::Client)
        allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
        allow(client_double).to receive(:list_peers).and_return([
          {
            name: "orders-node", url: "http://orders:4567", capabilities: [],
            metadata: { mesh_governance: { checkpoint: tampered } }
          }
        ])

        poller.poll_once

        expect(checkpoint_store.load).to be_nil
      end

      it "is a no-op when checkpoint_store is not configured" do
        config.checkpoint_store = nil
        stub_seed_with_checkpoint(remote_checkpoint)

        expect { poller.poll_once }.not_to raise_error
      end
    end
  end

  describe Igniter::Cluster::Mesh::GossipRound do
    let(:config) do
      Igniter::Cluster::Mesh::Config.new.tap do |c|
        c.peer_name    = "api-node"
        c.local_url    = "http://api:4567"
        c.gossip_fanout = 1
      end
    end
    subject(:gossip_round) { described_class.new(config) }

    let(:remote_identity) { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "orders-node") }
    let(:remote_trail) do
      Igniter::Cluster::Governance::Trail.new.tap do |t|
        t.record(:routing_plan_applied, source: :spec, payload: {})
      end
    end
    let(:remote_checkpoint) do
      Igniter::Cluster::Governance::Checkpoint.build(
        identity: remote_identity, peer_name: "orders-node", trail: remote_trail
      )
    end
    let(:checkpoint_store) do
      Igniter::Cluster::Governance::Stores::CheckpointStore.new(
        path: File.join(Dir.tmpdir, "igniter_test_cp_gossip_#{Process.pid}.json")
      )
    end

    before { config.checkpoint_store = checkpoint_store }
    after  { checkpoint_store.clear! }

    it "syncs a newer checkpoint received via gossip" do
      # Register a peer so GossipRound has a candidate
      peer = Igniter::Cluster::Mesh::Peer.new(
        name: "orders-node", url: "http://orders:4567",
        capabilities: [:orders], tags: [], metadata: {}
      )
      config.peer_registry.register(peer)

      client_double = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:list_peers).and_return([
        {
          name: "other-node",
          url: "http://other:4567",
          capabilities: [:api],
          metadata: {
            mesh_governance: {
              peer_name:       remote_checkpoint.peer_name,
              checkpointed_at: remote_checkpoint.checkpointed_at,
              crest_digest:    remote_checkpoint.crest_digest,
              checkpoint:      remote_checkpoint.to_h
            }
          }
        }
      ])

      gossip_round.run

      saved = checkpoint_store.load
      expect(saved).not_to be_nil
      expect(saved.crest_digest).to eq(remote_checkpoint.crest_digest)

      snap = config.governance_trail.snapshot(limit: 10)
      expect(snap[:by_type]).to include(checkpoint_replicated: 1)
    end
  end

  describe Igniter::Cluster::Mesh::RepairLoop do
    let(:config) do
      Igniter::Cluster::Mesh::Config.new.tap do |c|
        c.peer_name = "api-node"
        c.self_heal_interval = 0.05
      end
    end
    subject(:repair_loop) { described_class.new(config) }

    after { repair_loop.stop }

    it "starts not running" do
      expect(repair_loop).not_to be_running
    end

    it "heal_once executes automated plans from the configured provider" do
      config.self_heal_report_provider = lambda do
        {
          routing: {
            plans: [
              {
                action: :refresh_peer_health,
                scope: :mesh_health,
                automated: true,
                requires_approval: false,
                params: {
                  peer_name: "orders-node",
                  selected_url: "http://orders:4567"
                }
              }
            ]
          }
        }
      end
      client_double = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
      allow(Igniter::Server::Client).to receive(:new).with("http://orders:4567", timeout: 3).and_return(client_double)

      result = repair_loop.heal_once

      expect(result).to be_applied
      expect(result.summary).to include(status: :applied, total: 1, applied: 1, automated_only: true)
      expect(result.applied).to contain_exactly(
        include(
          action: :refresh_peer_health,
          peer_name: "orders-node",
          selected_url: "http://orders:4567",
          reachable: true
        )
      )
      expect(config.governance_trail.snapshot(limit: 10)).to include(
        total: 3,
        latest_type: :routing_self_heal_tick,
        by_type: include(
          peer_health_refreshed: 1,
          routing_plan_applied: 1,
          routing_self_heal_tick: 1
        )
      )
    end

    it "heal_once returns idle when no report is available" do
      result = repair_loop.heal_once

      expect(result.summary).to include(status: :idle, reason: :no_report, total: 0)
    end

    it "background thread calls heal_once periodically" do
      call_count = 0
      allow(repair_loop).to receive(:heal_once) { call_count += 1 }

      repair_loop.start
      sleep(0.25)
      repair_loop.stop

      expect(call_count).to be >= 2
    end

    context "workload tick" do
      let(:tracker) { Igniter::Cluster::Mesh::WorkloadTracker.new }
      let(:orders_peer) do
        Igniter::Cluster::Mesh::Peer.new(
          name: "orders-node", url: "http://orders:4567",
          capabilities: [:api], tags: [], metadata: {}
        )
      end
      let(:config) do
        Igniter::Cluster::Mesh::Config.new.tap do |c|
          c.peer_name          = "api-node"
          c.self_heal_interval = 0.05
          c.workload_tracker   = tracker
        end
      end

      before { config.peer_registry.register(orders_peer) }

      it "records :workload_self_heal_tick when degraded peers exist" do
        5.times { tracker.record("orders-node", :api, success: false) }

        expect(tracker.degraded_peers).to include("orders-node")

        repair_loop.heal_once

        snap = config.governance_trail.snapshot(limit: 10)
        expect(snap[:by_type]).to include(workload_self_heal_tick: 1)
        expect(snap[:latest_type]).to eq(:workload_self_heal_tick)
      end

      it "workload_self_heal_tick payload lists degraded and overloaded peers" do
        slow_peer = Igniter::Cluster::Mesh::Peer.new(
          name: "slow-node", url: "http://slow:4567",
          capabilities: [:api], tags: [], metadata: {}
        )
        config.peer_registry.register(slow_peer)
        5.times { tracker.record("slow-node", :api, success: false) }

        repair_loop.heal_once

        event = config.governance_trail.events.find { |e| e[:type] == :workload_self_heal_tick }
        expect(event).not_to be_nil
        expect(event[:payload][:degraded]).to include("slow-node")
        expect(event[:payload][:plans]).to be >= 1
      end

      it "does not record :workload_self_heal_tick when all peers are healthy" do
        repair_loop.heal_once

        snap = config.governance_trail.snapshot(limit: 10)
        expect(snap[:by_type].keys).not_to include(:workload_self_heal_tick)
      end

      it "heal_once still returns routing RoutingPlanResult (backward-compat)" do
        5.times { tracker.record("orders-node", :api, success: false) }

        result = repair_loop.heal_once

        expect(result).to be_a(Igniter::Cluster::RoutingPlanResult)
        expect(result.summary).to include(status: :idle, reason: :no_report)
      end

      it "workload heal is skipped when workload_tracker is nil" do
        config.workload_tracker = nil
        repair_loop_no_wl = described_class.new(config)

        expect { repair_loop_no_wl.heal_once }.not_to raise_error
        repair_loop_no_wl.stop
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Discovery
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Discovery do
    let(:config) do
      Igniter::Cluster::Mesh::Config.new.tap do |c|
        c.peer_name = "api-node"
        c.local_url = "http://api:4567"
        c.seeds     = %w[http://seed1:4567]
      end
    end
    subject(:discovery) { described_class.new(config) }

    let(:announcer_double) { instance_double(Igniter::Cluster::Mesh::Announcer, announce_all: nil, deannounce_all: nil) }
    let(:poller_double)    { instance_double(Igniter::Cluster::Mesh::Poller, poll_once: nil, start: nil, stop: nil, running?: false) }
    let(:repair_loop_double) { instance_double(Igniter::Cluster::Mesh::RepairLoop, start: nil, stop: nil, running?: false) }

    before do
      allow(Igniter::Cluster::Mesh::Announcer).to receive(:new).and_return(announcer_double)
      allow(Igniter::Cluster::Mesh::Poller).to receive(:new).and_return(poller_double)
      allow(Igniter::Cluster::Mesh::RepairLoop).to receive(:new).and_return(repair_loop_double)
    end

    it "start triggers announce_all, poll_once, and poller.start" do
      discovery.start

      expect(announcer_double).to have_received(:announce_all)
      expect(poller_double).to have_received(:poll_once)
      expect(poller_double).to have_received(:start)
      expect(repair_loop_double).not_to have_received(:start)
    end

    it "start also launches repair_loop when auto_self_heal is enabled" do
      config.auto_self_heal = true

      discovery.start

      expect(repair_loop_double).to have_received(:start)
    end

    it "stop triggers deannounce_all and poller.stop" do
      discovery.stop

      expect(announcer_double).to have_received(:deannounce_all)
      expect(poller_double).to have_received(:stop)
      expect(repair_loop_double).to have_received(:stop)
    end

    it "running? delegates to poller" do
      allow(poller_double).to receive(:running?).and_return(true)
      expect(discovery).to be_running
    end

    it "start returns self" do
      expect(discovery.start).to be(discovery)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Mesh module — start/stop_discovery!
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Igniter::Cluster::Mesh module" do
    it "start_discovery! starts discovery and returns self" do
      disc = instance_double(Igniter::Cluster::Mesh::Discovery, start: nil, stop: nil, running?: true)
      allow(Igniter::Cluster::Mesh::Discovery).to receive(:new).and_return(disc)

      result = Igniter::Cluster::Mesh.start_discovery!

      expect(disc).to have_received(:start)
      expect(result).to be(Igniter::Cluster::Mesh)
    end

    it "stop_discovery! stops discovery and clears the singleton" do
      disc = instance_double(Igniter::Cluster::Mesh::Discovery, start: nil, stop: nil, running?: false)
      allow(Igniter::Cluster::Mesh::Discovery).to receive(:new).and_return(disc)
      Igniter::Cluster::Mesh.start_discovery!

      Igniter::Cluster::Mesh.stop_discovery!

      expect(disc).to have_received(:stop)
      expect(Igniter::Cluster::Mesh.instance_variable_get(:@discovery)).to be_nil
    end

    it "reset! stops discovery and clears config + router" do
      Igniter::Cluster::Mesh.configure { |c| c.peer_name = "x" }
      disc = instance_double(Igniter::Cluster::Mesh::Discovery, start: nil, stop: nil, running?: false)
      allow(Igniter::Cluster::Mesh::Discovery).to receive(:new).and_return(disc)
      Igniter::Cluster::Mesh.start_discovery!

      Igniter::Cluster::Mesh.reset!

      expect(disc).to have_received(:stop)
      expect(Igniter::Cluster::Mesh.instance_variable_get(:@config)).to be_nil
      expect(Igniter::Cluster::Mesh.instance_variable_get(:@router)).to be_nil
    end

    it "start_repair_loop! starts repair loop and returns self" do
      loop_double = instance_double(Igniter::Cluster::Mesh::RepairLoop, start: nil, stop: nil, running?: true)
      allow(Igniter::Cluster::Mesh::RepairLoop).to receive(:new).and_return(loop_double)

      result = Igniter::Cluster::Mesh.start_repair_loop!

      expect(loop_double).to have_received(:start)
      expect(result).to be(Igniter::Cluster::Mesh)
    end

    it "stop_repair_loop! stops repair loop and clears the singleton" do
      loop_double = instance_double(Igniter::Cluster::Mesh::RepairLoop, start: nil, stop: nil, running?: false)
      allow(Igniter::Cluster::Mesh::RepairLoop).to receive(:new).and_return(loop_double)
      Igniter::Cluster::Mesh.start_repair_loop!

      Igniter::Cluster::Mesh.stop_repair_loop!

      expect(loop_double).to have_received(:stop)
      expect(Igniter::Cluster::Mesh.instance_variable_get(:@repair_loop)).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Router — merged static + dynamic routing
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Router, "merged peer routing" do
    let(:config) { Igniter::Cluster::Mesh::Config.new }
    let(:router) { described_class.new(config) }

    def stub_alive(url)
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 3).and_return(client)
      allow(client).to receive(:health).and_return({ "status" => "ok" })
    end

    def stub_dead(url)
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 3).and_return(client)
      allow(client).to receive(:health).and_raise(Igniter::Server::Client::ConnectionError, "refused")
    end

    let(:deferred) { Igniter::Runtime::DeferredResult.build(payload: {}, source_node: :x, waiting_on: :x) }

    it "finds a dynamic peer when no static peers are configured" do
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "dyn-orders", url: "http://dyn:4567", capabilities: [:orders], tags: [:linux])
      )
      stub_alive("http://dyn:4567")

      url = router.find_peer_for(:orders, deferred)
      expect(url).to eq("http://dyn:4567")
    end

    it "static peer takes precedence over same-named dynamic peer" do
      config.add_peer("orders-node", url: "http://static:4567", capabilities: [:orders], tags: [:linux])
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "orders-node", url: "http://dynamic:4567", capabilities: [:orders], tags: [:darwin])
      )
      stub_alive("http://static:4567")

      url = router.find_peer_for(:orders, deferred)
      expect(url).to eq("http://static:4567")
    end

    it "falls back to dynamic peer when static peer with same capability is dead" do
      config.add_peer("static-orders", url: "http://static:4567", capabilities: [:orders], tags: [:darwin])
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "dyn-orders", url: "http://dyn:4567", capabilities: [:orders], tags: [:linux])
      )
      stub_dead("http://static:4567")
      stub_alive("http://dyn:4567")

      url = router.find_peer_for(:orders, deferred)
      expect(url).to eq("http://dyn:4567")
    end

    it "raises DeferredCapabilityError when all peers (static + dynamic) are dead" do
      config.add_peer("s", url: "http://s:4567", capabilities: [:orders])
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "d", url: "http://d:4567", capabilities: [:orders])
      )
      stub_dead("http://s:4567")
      stub_dead("http://d:4567")

      expect { router.find_peer_for(:orders, deferred) }
        .to raise_error(Igniter::Cluster::Mesh::DeferredCapabilityError)
    end

    it "finds a peer by capability query across merged static and dynamic pools" do
      config.add_peer("linux-orders", url: "http://linux:4567", capabilities: [:orders], tags: [:linux])
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "mac-orders", url: "http://mac:4567", capabilities: [:orders], tags: [:darwin])
      )
      stub_alive("http://linux:4567")
      stub_alive("http://mac:4567")

      expect(router.find_peer_for_query({ all_of: [:orders], tags: [:linux] }, deferred)).to eq("http://linux:4567")
    end

    it "resolve_pinned finds a dynamic peer by name" do
      config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "audit-node", url: "http://audit:4567", capabilities: [:audit])
      )
      stub_alive("http://audit:4567")

      url = router.resolve_pinned("audit-node")
      expect(url).to eq("http://audit:4567")
    end

    it "resolve_pinned raises IncidentError when peer exists nowhere" do
      expect { router.resolve_pinned("ghost") }
        .to raise_error(Igniter::Cluster::Mesh::IncidentError)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Server handlers
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Server::Handlers::MeshPeersListHandler do
    subject(:handler) { described_class.new(double("registry"), double("store")) }

    it "returns empty array when Igniter::Cluster::Mesh is not configured" do
      # Force reset so no Mesh is configured
      result = handler.call(params: {}, body: {})
      expect(result[:status]).to eq(200)
      expect(JSON.parse(result[:body])).to eq([])
    end

    it "returns static peers" do
      Igniter::Cluster::Mesh.configure do |c|
        c.add_peer "orders-node", url: "http://orders:4567", capabilities: %i[orders]
      end

      result = handler.call(params: {}, body: {})
      data   = JSON.parse(result[:body])
      expect(data.size).to eq(1)
      expect(data.first["name"]).to eq("orders-node")
      expect(data.first["capabilities"]).to eq(["orders"])
    end

    it "returns dynamic peers" do
      Igniter::Cluster::Mesh.configure { |_c| }
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "dyn", url: "http://dyn:4567", capabilities: [:audit], tags: [:linux])
      )

      result = handler.call(params: {}, body: {})
      data   = JSON.parse(result[:body])
      expect(data.map { |p| p["name"] }).to include("dyn")
    end

    it "returns runtime mesh freshness for discovered peers" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      Igniter::Cluster::Mesh.configure { |_c| }
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(
          name: "dyn",
          url: "http://dyn:4567",
          capabilities: [:audit],
          metadata: {
            mesh: {
              observed_at: "2026-04-16T11:59:40Z",
              confidence: 0.9,
              hops: 1
            }
          }
        )
      )
      allow(Time).to receive(:now).and_return(now)

      result = handler.call(params: {}, body: {})
      data   = JSON.parse(result[:body])
      mesh   = data.first.fetch("metadata").fetch("mesh")

      expect(mesh["confidence"]).to eq(0.9)
      expect(mesh["hops"]).to eq(1)
      expect(mesh["freshness_seconds"]).to eq(20)
    end

    it "merges static + dynamic, static names win" do
      Igniter::Cluster::Mesh.configure do |c|
        c.add_peer "shared", url: "http://static:4567", capabilities: %i[orders]
      end
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "shared", url: "http://dynamic:4567", capabilities: [:orders])
      )
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "dynamic-only", url: "http://d2:4567", capabilities: [:audit])
      )

      result = handler.call(params: {}, body: {})
      data   = JSON.parse(result[:body])

      shared = data.find { |p| p["name"] == "shared" }
      expect(shared["url"]).to eq("http://static:4567")
      expect(data.map { |p| p["name"] }).to include("dynamic-only")
      expect(data.size).to eq(2)
    end
  end

  describe Igniter::Server::Handlers::MeshPeersRegisterHandler do
    subject(:handler) { described_class.new(double("registry"), double("store")) }

    before { Igniter::Cluster::Mesh.configure { |_c| } }

    it "registers a peer and returns 200" do
      body = { "name" => "orders-node", "url" => "http://orders:4567", "capabilities" => ["orders"] }
      result = handler.call(params: {}, body: body)

      expect(result[:status]).to eq(200)
      expect(JSON.parse(result[:body])["registered"]).to be true
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("orders-node")).not_to be_nil
    end

    it "returns 400 when name is missing" do
      result = handler.call(params: {}, body: { "url" => "http://x:4567" })
      expect(result[:status]).to eq(400)
      expect(JSON.parse(result[:body])["error"]).to match(/name/)
    end

    it "returns 400 when url is missing" do
      result = handler.call(params: {}, body: { "name" => "x" })
      expect(result[:status]).to eq(400)
      expect(JSON.parse(result[:body])["error"]).to match(/url/)
    end

    it "coerces capabilities to symbols in the registered peer" do
      body = { "name" => "x", "url" => "http://x:4567", "capabilities" => ["orders", "billing"] }
      handler.call(params: {}, body: body)

      peer = Igniter::Cluster::Mesh.config.peer_registry.peer_named("x")
      expect(peer.capabilities).to eq(%i[orders billing])
    end
  end

  describe Igniter::Server::Handlers::MeshPeersDeleteHandler do
    subject(:handler) { described_class.new(double("registry"), double("store")) }

    before { Igniter::Cluster::Mesh.configure { |_c| } }

    it "removes a registered peer and returns 200" do
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(name: "orders-node", url: "http://orders:4567")
      )

      result = handler.call(params: { name: "orders-node" }, body: {})

      expect(result[:status]).to eq(200)
      expect(JSON.parse(result[:body])["unregistered"]).to be true
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("orders-node")).to be_nil
    end

    it "is idempotent — returns 200 even for unknown peers" do
      result = handler.call(params: { name: "ghost" }, body: {})
      expect(result[:status]).to eq(200)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Server::Client mesh methods
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Server::Client do
    subject(:client) { described_class.new("http://seed:4567") }

    describe "#list_peers" do
      it "fetches and parses GET /v1/mesh/peers" do
        stub_response = [
          { "name" => "orders-node", "url" => "http://orders:4567", "capabilities" => ["orders"] }
        ]
        allow(client).to receive(:get).with("/v1/mesh/peers").and_return(stub_response)

        peers = client.list_peers
        expect(peers.size).to eq(1)
        expect(peers.first[:name]).to eq("orders-node")
        expect(peers.first[:capabilities]).to eq([:orders])
      end

      it "returns empty array when response is empty" do
        allow(client).to receive(:get).with("/v1/mesh/peers").and_return([])
        expect(client.list_peers).to eq([])
      end
    end

    describe "#register_peer" do
      it "POSTs to /v1/mesh/peers with correct payload" do
        allow(client).to receive(:post).with(
          "/v1/mesh/peers",
          {
            "name" => "api-node",
            "url" => "http://api:4567",
            "capabilities" => ["api"],
            "tags" => [],
            "metadata" => {}
          }
        ).and_return({ "registered" => true })

        client.register_peer(name: "api-node", url: "http://api:4567", capabilities: %i[api])
      end
    end

    describe "#unregister_peer" do
      it "sends DELETE to /v1/mesh/peers/:name" do
        allow(client).to receive(:delete_request).with("/v1/mesh/peers/orders-node").and_return({})
        client.unregister_peer("orders-node")
        expect(client).to have_received(:delete_request).with("/v1/mesh/peers/orders-node")
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Server route table
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Server::Router ROUTES" do
    let(:routes) { Igniter::Server::Router::ROUTES }

    it "includes GET /v1/mesh/peers" do
      expect(routes).to include(hash_including(method: "GET", handler: :mesh_peers_list))
    end

    it "includes POST /v1/mesh/peers" do
      expect(routes).to include(hash_including(method: "POST", handler: :mesh_peers_register))
    end

    it "includes DELETE /v1/mesh/peers/:name" do
      expect(routes).to include(hash_including(method: "DELETE", handler: :mesh_peers_delete))
    end

    it "DELETE pattern matches paths with hyphens and dots" do
      route = routes.find { |r| r[:handler] == :mesh_peers_delete }
      expect(route[:pattern]).to match("/v1/mesh/peers/orders-node")
      expect(route[:pattern]).to match("/v1/mesh/peers/orders.node.v2")
    end
  end
end
