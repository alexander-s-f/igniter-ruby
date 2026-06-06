# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter Mesh — Phase 3: Gossip Protocol" do
  after { Igniter::Cluster::Mesh.reset! }

  # ─── Shared helpers ─────────────────────────────────────────────────────────

  def make_peer(name, url, caps = [])
    Igniter::Cluster::Mesh::Peer.new(name: name, url: url, capabilities: Array(caps).map(&:to_sym))
  end

  def make_config(fanout: 3, local_url: "http://self:4567", peer_name: "self-node", seeds: [])
    Igniter::Cluster::Mesh.reset!
    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name          = peer_name
      c.local_url          = local_url
      c.gossip_fanout      = fanout
      c.seeds              = seeds
      c.discovery_interval = 60
    end
    Igniter::Cluster::Mesh.config
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Config defaults and assignment
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Config#gossip_fanout" do
    it "defaults to 3" do
      config = Igniter::Cluster::Mesh::Config.new
      expect(config.gossip_fanout).to eq(3)
    end

    it "can be set to 0 to disable gossip" do
      config = Igniter::Cluster::Mesh::Config.new
      config.gossip_fanout = 0
      expect(config.gossip_fanout).to eq(0)
    end

    it "can be set to an arbitrary positive integer" do
      config = Igniter::Cluster::Mesh::Config.new
      config.gossip_fanout = 10
      expect(config.gossip_fanout).to eq(10)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # GossipRound#run — pick_candidates
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::GossipRound do
    let(:config) { make_config(fanout: 3, local_url: "http://self:4567") }

    let(:peer_a) { make_peer("node-a", "http://node-a:4567", [:orders]) }
    let(:peer_b) { make_peer("node-b", "http://node-b:4567", [:audit]) }
    let(:peer_c) { make_peer("node-c", "http://node-c:4567", [:billing]) }
    let(:self_peer) { make_peer("self-node", "http://self:4567", [:api]) }

    def stub_list_peers(url, list)
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 5).and_return(client)
      allow(client).to receive(:list_peers).and_return(list)
    end

    def stub_connection_error(url)
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 5).and_return(client)
      allow(client).to receive(:list_peers).and_raise(Igniter::Server::Client::ConnectionError, "timeout")
    end

    describe "#run with empty registry" do
      it "does nothing when registry is empty" do
        expect(Igniter::Server::Client).not_to receive(:new)
        described_class.new(config).run
      end
    end

    describe "pick_candidates — excludes self" do
      it "does not contact self when self is in the registry" do
        config.peer_registry.register(self_peer) # same url as local_url
        config.peer_registry.register(peer_a)

        stub_list_peers(peer_a.url, [])

        # self_peer.url == config.local_url → should be excluded
        expect(Igniter::Server::Client).not_to receive(:new).with(self_peer.url, anything)
        described_class.new(config).run
      end
    end

    describe "pick_candidates — respects fanout count" do
      it "contacts at most gossip_fanout peers" do
        config.gossip_fanout = 2
        [peer_a, peer_b, peer_c].each { |p| config.peer_registry.register(p) }

        contacted = []
        allow(Igniter::Server::Client).to receive(:new) do |url, **|
          client = instance_double(Igniter::Server::Client)
          allow(client).to receive(:list_peers).and_return([])
          contacted << url
          client
        end

        described_class.new(config).run
        expect(contacted.size).to be <= 2
      end

      it "contacts all peers when registry size < fanout" do
        config.gossip_fanout = 10
        [peer_a, peer_b].each { |p| config.peer_registry.register(p) }

        contacted = []
        allow(Igniter::Server::Client).to receive(:new) do |url, **|
          client = instance_double(Igniter::Server::Client)
          allow(client).to receive(:list_peers).and_return([])
          contacted << url
          client
        end

        described_class.new(config).run
        expect(contacted.size).to eq(2)
      end
    end

    describe "exchange_with — registers discovered peers" do
      it "registers peers returned by the contacted node" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          { name: "node-d", url: "http://node-d:4567", capabilities: [:payments] }
                        ])

        described_class.new(config).run

        registered = config.peer_registry.peer_named("node-d")
        expect(registered).not_to be_nil
        expect(registered.url).to eq("http://node-d:4567")
        expect(registered.capabilities).to contain_exactly(:payments)
      end

      it "decays relay confidence and increments hops for discovered peers" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          {
                            name: "node-d",
                            url: "http://node-d:4567",
                            capabilities: [:payments],
                            metadata: {
                              mesh: {
                                observed_at: "2026-04-16T11:59:00Z",
                                confidence: 1.0,
                                hops: 0,
                                origin: "node-d"
                              }
                            }
                          }
                        ])

        described_class.new(config).run

        mesh = config.peer_registry.peer_named("node-d").metadata[:mesh]
        expect(mesh).to include(
          observed_at: "2026-04-16T11:59:00Z",
          confidence: 0.9,
          hops: 1,
          origin: "node-d",
          relayed_by: "node-a"
        )
      end

      it "registers multiple peers from one exchange" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          { name: "node-d", url: "http://node-d:4567", capabilities: [] },
                          { name: "node-e", url: "http://node-e:4567", capabilities: [:shipping] }
                        ])

        described_class.new(config).run

        expect(config.peer_registry.peer_named("node-d")).not_to be_nil
        expect(config.peer_registry.peer_named("node-e")).not_to be_nil
      end

      it "relays signed governance checkpoints from discovered peers" do
        identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "node-d")
        trail = Igniter::Cluster::Governance::Trail.new
        trail.record(:routing_plan_applied, source: :spec, payload: { step: 1 })
        checkpoint = Igniter::Cluster::Governance::Checkpoint.build(
          identity: identity,
          peer_name: "node-d",
          trail: trail
        )

        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          {
                            name: "node-d",
                            url: "http://node-d:4567",
                            capabilities: [:payments],
                            metadata: {
                              mesh_governance: {
                                checkpointed_at: checkpoint.checkpointed_at,
                                crest_digest: checkpoint.crest_digest,
                                checkpoint: checkpoint.to_h
                              }
                            }
                          }
                        ])

        described_class.new(config).run

        governance = config.peer_registry.peer_named("node-d").metadata[:mesh_governance]
        expect(governance).to include(
          node_id: "node-d",
          crest_digest: checkpoint.crest_digest,
          checkpointed_at: checkpoint.checkpointed_at,
          checkpoint: hash_including(node_id: "node-d"),
          trust: include(status: :unknown, trusted: false)
        )
      end

      it "skips entries with nil name" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          { name: nil, url: "http://bad:4567", capabilities: [] }
                        ])

        expect { described_class.new(config).run }.not_to raise_error
        expect(config.peer_registry.size).to eq(1) # only peer_a itself
      end

      it "skips entries with nil url" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          { name: "broken-node", url: nil, capabilities: [] }
                        ])

        expect { described_class.new(config).run }.not_to raise_error
        expect(config.peer_registry.peer_named("broken-node")).to be_nil
      end

      it "skips self (peer_name match)" do
        config.peer_registry.register(peer_a)
        stub_list_peers(peer_a.url, [
                          { name: config.peer_name, url: "http://self-alias:4567", capabilities: [] }
                        ])

        described_class.new(config).run
        # Self should not appear as a new registry entry under a different url
        expect(config.peer_registry.peer_named(config.peer_name)).to be_nil
      end
    end

    describe "exchange_with — error handling" do
      it "swallows ConnectionError and continues with remaining candidates" do
        config.gossip_fanout = 2
        config.peer_registry.register(peer_a)
        config.peer_registry.register(peer_b)

        # Make peer_a raise, peer_b return a new peer
        allow(Igniter::Server::Client).to receive(:new) do |url, **|
          client = instance_double(Igniter::Server::Client)
          if url == peer_a.url
            allow(client).to receive(:list_peers).and_raise(Igniter::Server::Client::ConnectionError, "down")
          else
            allow(client).to receive(:list_peers).and_return([
                                                               { name: "node-x", url: "http://node-x:4567", capabilities: [:search] }
                                                             ])
          end
          client
        end

        # Should not raise even though one peer is down
        expect { described_class.new(config).run }.not_to raise_error
      end

      it "does not raise when all candidates are offline" do
        config.peer_registry.register(peer_a)
        stub_connection_error(peer_a.url)

        expect { described_class.new(config).run }.not_to raise_error
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Convergence scenario
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Convergence" do
    it "C discovers B by gossiping with A (A knows B, C only knows A)" do
      Igniter::Cluster::Mesh.reset!

      # Set up config for node C
      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name          = "node-c"
        c.local_url          = "http://node-c:4567"
        c.gossip_fanout      = 1
        c.discovery_interval = 60
      end

      config = Igniter::Cluster::Mesh.config

      peer_a = make_peer("node-a", "http://node-a:4567", [:orders])
      peer_b = make_peer("node-b", "http://node-b:4567", [:audit])

      # C only knows A
      config.peer_registry.register(peer_a)

      # A's GET /v1/mesh/peers returns B
      client_a = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with("http://node-a:4567", timeout: 5).and_return(client_a)
      allow(client_a).to receive(:list_peers).and_return([
                                                           { name: peer_b.name, url: peer_b.url,
                                                             capabilities: peer_b.capabilities }
                                                         ])

      Igniter::Cluster::Mesh::GossipRound.new(config).run

      # After gossip, C should know B
      expect(config.peer_registry.peer_named("node-b")).not_to be_nil
      expect(config.peer_registry.peer_named("node-b").url).to eq("http://node-b:4567")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Poller integration
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Poller#poll_once" do
    let(:config) do
      make_config(fanout: 3, local_url: "http://self:4567", seeds: ["http://seed:4567"])
    end

    def stub_seed_empty
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with("http://seed:4567", timeout: 5).and_return(client)
      allow(client).to receive(:list_peers).and_return([])
    end

    it "calls GossipRound#run when gossip_fanout > 0" do
      stub_seed_empty
      gossip = instance_double(Igniter::Cluster::Mesh::GossipRound)
      allow(gossip).to receive(:run)
      allow(Igniter::Cluster::Mesh::GossipRound).to receive(:new).with(config).and_return(gossip)

      Igniter::Cluster::Mesh::Poller.new(config).poll_once

      expect(gossip).to have_received(:run)
    end

    it "skips GossipRound when gossip_fanout == 0" do
      config.gossip_fanout = 0
      stub_seed_empty

      expect(Igniter::Cluster::Mesh::GossipRound).not_to receive(:new)
      Igniter::Cluster::Mesh::Poller.new(config).poll_once
    end

    it "does not raise when registry is empty and fanout > 0" do
      stub_seed_empty
      expect { Igniter::Cluster::Mesh::Poller.new(config).poll_once }.not_to raise_error
    end

    it "runs gossip after seed polling" do
      call_order = []

      seed_client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with("http://seed:4567", timeout: 5).and_return(seed_client)
      allow(seed_client).to receive(:list_peers) do
        call_order << :seed
        []
      end

      gossip = instance_double(Igniter::Cluster::Mesh::GossipRound)
      allow(Igniter::Cluster::Mesh::GossipRound).to receive(:new).with(config).and_return(gossip)
      allow(gossip).to receive(:run) { call_order << :gossip }

      Igniter::Cluster::Mesh::Poller.new(config).poll_once

      expect(call_order).to eq(%i[seed gossip])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # start_discovery! with gossip_fanout = 0
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Igniter::Cluster::Mesh.start_discovery! with gossip_fanout = 0" do
    it "disables gossip without raising" do
      allow_any_instance_of(Igniter::Cluster::Mesh::Announcer).to receive(:announce_all)

      seed_client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with("http://seed:4567", timeout: 5).and_return(seed_client)
      allow(seed_client).to receive(:list_peers).and_return([])
      allow(seed_client).to receive(:unregister_peer)

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name          = "api-node"
        c.local_url          = "http://api:4567"
        c.seeds              = %w[http://seed:4567]
        c.gossip_fanout      = 0
        c.discovery_interval = 60
      end

      expect { Igniter::Cluster::Mesh.start_discovery! }.not_to raise_error
    ensure
      Igniter::Cluster::Mesh.stop_discovery!
    end
  end
end
