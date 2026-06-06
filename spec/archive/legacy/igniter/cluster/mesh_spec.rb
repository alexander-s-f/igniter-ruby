# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter Mesh — Phase 1: Static Mesh" do
  # ─────────────────────────────────────────────────────────────────────────────
  # Peer
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Peer do
    subject(:peer) do
      described_class.new(
        name: "orders-node",
        url: "http://orders.internal:4567/",
        capabilities: [:orders, :inventory],
        tags: [:linux]
      )
    end

    it "stores name, url and capabilities" do
      expect(peer.name).to eq("orders-node")
      expect(peer.url).to eq("http://orders.internal:4567") # trailing slash stripped
      expect(peer.capabilities).to eq(%i[orders inventory])
      expect(peer.tags).to eq([:linux])
    end

    it "is frozen" do
      expect(peer).to be_frozen
    end

    it "#capable? returns true for known capability" do
      expect(peer.capable?(:orders)).to be true
      expect(peer.capable?("inventory")).to be true
    end

    it "#capable? returns false for unknown capability" do
      expect(peer.capable?(:billing)).to be false
    end

    it "matches a capability query across capabilities and tags" do
      expect(peer.matches_query?(all_of: [:orders], tags: [:linux])).to be true
      expect(peer.matches_query?(all_of: [:orders], tags: [:darwin])).to be false
    end

    it "matches a capability query across peer metadata" do
      peer_with_metadata = described_class.new(
        name: "orders-node",
        url: "http://orders.internal:4567",
        capabilities: [:orders],
        metadata: { trust: { score: 0.95 }, region: "eu-central" }
      )

      expect(peer_with_metadata.matches_query?(metadata: { trust: { score: { min: 0.9 } }, region: "eu-central" })).to be true
      expect(peer_with_metadata.matches_query?(metadata: { trust: { score: { min: 0.99 } } })).to be false
    end

    it "derives mesh freshness from observed_at in the runtime profile" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      peer_with_mesh = described_class.new(
        name: "orders-node",
        url: "http://orders.internal:4567",
        capabilities: [:orders],
        metadata: {
          mesh: {
            observed_at: "2026-04-16T11:59:30Z",
            confidence: 0.85,
            hops: 1
          }
        }
      )

      allow(Time).to receive(:now).and_return(now)

      expect(peer_with_mesh.profile.metadata[:mesh]).to include(
        observed_at: "2026-04-16T11:59:30Z",
        confidence: 0.85,
        hops: 1,
        freshness_seconds: 30
      )
    end

    it "derives attestation freshness from mesh_capabilities observed_at in the runtime profile" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      peer_with_attestation = described_class.new(
        name: "orders-node",
        url: "http://orders.internal:4567",
        capabilities: [:orders],
        metadata: {
          mesh_capabilities: {
            observed_at: "2026-04-16T11:59:40Z",
            trust: { status: :trusted }
          }
        }
      )

      allow(Time).to receive(:now).and_return(now)

      expect(peer_with_attestation.profile.metadata[:mesh_capabilities]).to include(
        observed_at: "2026-04-16T11:59:40Z",
        freshness_seconds: 20
      )
    end

    it "derives governance checkpoint freshness from mesh_governance checkpointed_at in the runtime profile" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      peer_with_governance = described_class.new(
        name: "orders-node",
        url: "http://orders.internal:4567",
        capabilities: [:orders],
        metadata: {
          mesh_governance: {
            checkpointed_at: "2026-04-16T11:59:45Z",
            trust: { status: :trusted }
          }
        }
      )

      allow(Time).to receive(:now).and_return(now)

      expect(peer_with_governance.profile.metadata[:mesh_governance]).to include(
        checkpointed_at: "2026-04-16T11:59:45Z",
        freshness_seconds: 15
      )
    end

    it "coerces capabilities to symbols" do
      p = described_class.new(name: "x", url: "http://x", capabilities: %w[audit])
      expect(p.capabilities).to eq([:audit])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Config
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Config do
    subject(:config) { described_class.new }

    it "starts with empty peers and nil peer_name" do
      expect(config.peers).to be_empty
      expect(config.peer_name).to be_nil
      expect(config.local_capabilities).to be_empty
    end

    it "add_peer registers peers" do
      config.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
      expect(config.peers.size).to eq(1)
      expect(config.peers.first.name).to eq("orders-node")
    end

    it "add_peer is chainable" do
      result = config.add_peer("a", url: "http://a").add_peer("b", url: "http://b")
      expect(result).to be(config)
      expect(config.peers.size).to eq(2)
    end

    it "peers_with_capability filters by capability" do
      config.add_peer("a", url: "http://a", capabilities: [:orders])
      config.add_peer("b", url: "http://b", capabilities: [:audit])
      config.add_peer("c", url: "http://c", capabilities: [:orders, :audit])
      expect(config.peers_with_capability(:orders).map(&:name)).to contain_exactly("a", "c")
    end

    it "peers_matching_query filters by capability query" do
      config.add_peer("a", url: "http://a", capabilities: [:orders], tags: [:linux])
      config.add_peer("b", url: "http://b", capabilities: [:orders], tags: [:darwin])
      expect(config.peers_matching_query(all_of: [:orders], tags: [:linux]).map(&:name)).to contain_exactly("a")
    end

    it "peer_named returns the matching peer or nil" do
      config.add_peer("orders-node", url: "http://orders:4567")
      expect(config.peer_named("orders-node")).not_to be_nil
      expect(config.peer_named("missing")).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Errors
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::DeferredCapabilityError do
    let(:deferred) { Igniter::Runtime::DeferredResult.build(payload: {}, source_node: :x, waiting_on: :x) }

    it "is a PendingDependencyError" do
      expect(described_class.ancestors).to include(Igniter::PendingDependencyError)
    end

    it "stores capability and deferred_result" do
      err = described_class.new(:orders, deferred)
      expect(err.capability).to eq(:orders)
      expect(err.deferred_result).to be(deferred)
    end

    it "stores optional routing explanation" do
      explanation = { selected_url: nil, peers: [] }
      err = described_class.new(:orders, deferred, query: { all_of: [:orders] }, explanation: explanation)
      expect(err.explanation).to eq(explanation)
    end

    it "uses a default message" do
      err = described_class.new(:orders, deferred)
      expect(err.message).to include("orders")
    end
  end

  describe Igniter::Cluster::Mesh::IncidentError do
    it "is a ResolutionError" do
      expect(described_class.ancestors).to include(Igniter::ResolutionError)
    end

    it "stores peer_name" do
      err = described_class.new("audit-node")
      expect(err.peer_name).to eq("audit-node")
    end

    it "uses a default message mentioning the peer" do
      err = described_class.new("audit-node")
      expect(err.message).to include("audit-node")
    end

    it "accepts a custom message" do
      err = described_class.new("audit-node", "custom")
      expect(err.message).to include("custom")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Mesh module
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh do
    after { described_class.reset! }

    it "configure yields the config" do
      described_class.configure do |c|
        c.peer_name = "api-node"
      end
      expect(described_class.config.peer_name).to eq("api-node")
    end

    it "router is a singleton" do
      expect(described_class.router).to be_a(Igniter::Cluster::Mesh::Router)
      expect(described_class.router).to be(described_class.router)
    end

    it "reset! clears config and router" do
      described_class.configure { |c| c.peer_name = "x" }
      described_class.router
      described_class.reset!
      expect(described_class.config.peer_name).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Router
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Cluster::Mesh::Router do
    let(:config) { Igniter::Cluster::Mesh::Config.new }
    let(:router) { described_class.new(config) }
    let(:deferred) { Igniter::Runtime::DeferredResult.build(payload: {}, source_node: :x, waiting_on: :x) }

    def stub_alive(url)
      client = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 3).and_return(client)
    end

    def stub_dead(url)
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 3).and_return(client)
      allow(client).to receive(:health).and_raise(Igniter::Server::Client::ConnectionError, "refused")
    end

    it "find_peer_for raises DeferredCapabilityError when no peers registered" do
      expect {
        router.find_peer_for(:orders, deferred)
      }.to raise_error(Igniter::Cluster::Mesh::DeferredCapabilityError) { |e| expect(e.capability).to eq(:orders) }
    end

    it "find_peer_for raises DeferredCapabilityError when all peers dead" do
      config.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
      stub_dead("http://orders:4567")
      expect {
        router.find_peer_for(:orders, deferred)
      }.to raise_error(Igniter::Cluster::Mesh::DeferredCapabilityError)
    end

    it "attaches explainability data when no alive peer is available" do
      config.add_peer("orders-dead", url: "http://orders-dead:4567", capabilities: [:orders], tags: [:linux])
      config.add_peer("orders-mac", url: "http://orders-mac:4567", capabilities: [:orders], tags: [:darwin])
      stub_dead("http://orders-dead:4567")

      expect {
        router.find_peer_for_query({ all_of: [:orders], tags: [:linux] }, deferred)
      }.to raise_error(Igniter::Cluster::Mesh::DeferredCapabilityError) { |error|
        expect(error.explanation).to include(
          selected_url: nil,
          matched_count: 1,
          eligible_count: 0
        )

        dead = error.explanation[:peers].find { |peer| peer[:name] == "orders-dead" }
        mac = error.explanation[:peers].find { |peer| peer[:name] == "orders-mac" }

        expect(dead).to include(matched: true, alive: false, reasons: [:unreachable])
        expect(mac).to include(matched: false, reasons: [:query_mismatch])
        expect(mac[:match_details]).to include(failed_dimensions: [:tags])
      }
    end

    it "explains peer selection and rejected candidates without mutating routing state" do
      config.add_peer("orders-linux", url: "http://orders-linux:4567", capabilities: [:orders], tags: [:linux], metadata: { trust: { score: 0.95 } })
      config.add_peer("orders-low", url: "http://orders-low:4567", capabilities: [:orders], tags: [:linux], metadata: { trust: { score: 0.80 } })
      config.add_peer("orders-mac", url: "http://orders-mac:4567", capabilities: [:orders], tags: [:darwin], metadata: { trust: { score: 0.99 } })
      stub_alive("http://orders-linux:4567")
      stub_alive("http://orders-low:4567")

      explanation = router.explain_peer_for_query(
        {
          all_of: [:orders],
          tags: [:linux],
          order_by: [{ metadata: "trust.score", direction: :desc }]
        }
      )

      expect(explanation).to include(
        selected_url: "http://orders-linux:4567",
        selected_peer: "orders-linux",
        matched_count: 2,
        eligible_count: 2,
        top_tier_count: 1
      )

      selected = explanation[:peers].find { |peer| peer[:name] == "orders-linux" }
      lower = explanation[:peers].find { |peer| peer[:name] == "orders-low" }
      mismatch = explanation[:peers].find { |peer| peer[:name] == "orders-mac" }

      expect(selected).to include(selected: true, top_tier: true, reasons: [:selected])
      expect(lower).to include(selected: false, top_tier: false, reasons: [:lower_ranked])
      expect(mismatch).to include(matched: false, reasons: [:query_mismatch])
      expect(mismatch[:match_details]).to include(failed_dimensions: [:tags])

      expect(router.find_peer_for_query({ all_of: [:orders], tags: [:linux], order_by: [{ metadata: "trust.score", direction: :desc }] }, deferred))
        .to eq("http://orders-linux:4567")
    end

    it "explains policy and decision mismatches for rejected peers" do
      config.add_peer(
        "orders-guarded",
        url: "http://orders-guarded:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      explanation = router.explain_peer_for_query(
        {
          all_of: [:orders],
          policy: { permits: [:shell_exec] },
          decision: { mode: :auto_only, actions: [:shell_exec] }
        }
      )

      guarded = explanation[:peers].find { |peer| peer[:name] == "orders-guarded" }

      expect(guarded).to include(matched: false, reasons: [:query_mismatch])
      expect(guarded[:match_details]).to include(failed_dimensions: %i[policy decision])
      expect(guarded[:match_details][:policy]).to include(failed_keys: [:permits])
      expect(guarded[:match_details][:decision]).to include(mode: :auto_only, outcome: :approval_required)
    end

    it "find_peer_for returns URL of alive peer" do
      config.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
      stub_alive("http://orders:4567")
      expect(router.find_peer_for(:orders, deferred)).to eq("http://orders:4567")
    end

    it "find_peer_for_query matches richer capability queries" do
      config.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders], tags: [:linux], metadata: { trust: { score: 0.95 } })
      config.add_peer("orders-mac", url: "http://orders-mac:4567", capabilities: [:orders], tags: [:darwin])
      stub_alive("http://orders:4567")
      stub_alive("http://orders-mac:4567")

      expect(router.find_peer_for_query({ all_of: [:orders], tags: [:linux], metadata: { trust: { score: { min: 0.9 } } } }, deferred)).to eq("http://orders:4567")
    end

    it "supports policy-aware routing shortcuts in queries" do
      config.add_peer(
        "orders-safe",
        url: "http://orders-safe:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )
      config.add_peer(
        "orders-unsafe",
        url: "http://orders-unsafe:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec filesystem_write],
            requires_approval: [:shell_exec],
            denies: [:filesystem_write]
          }
        }
      )
      stub_alive("http://orders-safe:4567")
      stub_alive("http://orders-unsafe:4567")

      query = {
        all_of: [:orders],
        policy: {
          permits: [:system_read],
          approvable: [:shell_exec],
          forbidden: [:filesystem_write]
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-unsafe:4567")
    end

    it "supports explicit trust requirements in capability queries" do
      config.add_peer(
        "orders-trusted",
        url: "http://orders-trusted:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:55Z"
          },
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:58Z"
          }
        }
      )
      config.add_peer(
        "orders-unknown",
        url: "http://orders-unknown:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :unknown },
          mesh_capabilities: {
            trust: { status: :unknown },
            observed_at: "2026-04-16T11:59:55Z"
          },
          mesh_governance: {
            trust: { status: :unknown },
            checkpointed_at: "2026-04-16T11:59:58Z"
          }
        }
      )
      stub_alive("http://orders-trusted:4567")
      stub_alive("http://orders-unknown:4567")
      allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 16, 12, 0, 0))

      query = {
        all_of: [:orders],
        trust: {
          identity: :trusted,
          attestation: :trusted,
          attestation_freshness_seconds: { max: 30 },
          governance: :trusted,
          governance_freshness_seconds: { max: 30 }
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-trusted:4567")
    end

    it "explains trust mismatches for rejected peers" do
      config.add_peer(
        "orders-unknown",
        url: "http://orders-unknown:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :unknown },
          mesh_capabilities: {
            trust: { status: :unknown },
            observed_at: "2026-04-16T11:59:55Z"
          },
          mesh_governance: {
            trust: { status: :unknown },
            checkpointed_at: "2026-04-16T11:59:58Z"
          }
        }
      )

      explanation = router.explain_peer_for_query(
        {
          all_of: [:orders],
          trust: { identity: :trusted, attestation: :trusted, governance: :trusted }
        }
      )

      candidate = explanation[:peers].find { |peer| peer[:name] == "orders-unknown" }

      expect(candidate).to include(matched: false, reasons: [:query_mismatch])
      expect(candidate[:match_details]).to include(failed_dimensions: [:trust])
      expect(candidate[:match_details][:trust]).to include(failed_keys: %i[identity attestation governance])
    end

    it "supports explicit governance requirements in capability queries" do
      config.add_peer(
        "orders-governed",
        url: "http://orders-governed:4567",
        capabilities: [:orders],
        metadata: {
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:58Z",
            freshness_seconds: 2,
            latest_type: :routing_plan_applied,
            blocked_events: 1,
            applied_events: 4
          }
        }
      )
      config.add_peer(
        "orders-blocked",
        url: "http://orders-blocked:4567",
        capabilities: [:orders],
        metadata: {
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:58Z",
            freshness_seconds: 2,
            latest_type: :routing_plan_blocked,
            blocked_events: 4,
            applied_events: 1
          }
        }
      )
      stub_alive("http://orders-governed:4567")
      stub_alive("http://orders-blocked:4567")

      query = {
        all_of: [:orders],
        governance: {
          trust: :trusted,
          latest_type: :routing_plan_applied,
          blocked_events: { max: 1 },
          applied_events: { min: 3 }
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-governed:4567")
    end

    it "explains governance mismatches for rejected peers" do
      config.add_peer(
        "orders-blocked",
        url: "http://orders-blocked:4567",
        capabilities: [:orders],
        metadata: {
          mesh_governance: {
            trust: { status: :trusted },
            latest_type: :routing_plan_blocked,
            blocked_events: 4,
            applied_events: 1
          }
        }
      )

      explanation = router.explain_peer_for_query(
        {
          all_of: [:orders],
          governance: {
            latest_type: :routing_plan_applied,
            blocked_events: { max: 1 }
          }
        }
      )

      candidate = explanation[:peers].find { |peer| peer[:name] == "orders-blocked" }

      expect(candidate).to include(matched: false, reasons: [:query_mismatch])
      expect(candidate[:match_details]).to include(failed_dimensions: [:governance])
      expect(candidate[:match_details][:governance]).to include(failed_keys: %i[latest_type blocked_events])
    end

    it "prefers automatic peers over approval-required peers in approval_ok mode" do
      config.add_peer(
        "orders-auto",
        url: "http://orders-auto:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: [:shell_exec]
          }
        }
      )
      config.add_peer(
        "orders-approval",
        url: "http://orders-approval:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: [:shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )
      stub_alive("http://orders-auto:4567")
      stub_alive("http://orders-approval:4567")

      query = {
        all_of: [:orders],
        decision: {
          mode: :approval_ok,
          actions: [:shell_exec]
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-auto:4567")
    end

    it "filters out peers that do not deny risky capabilities in deny_risky mode" do
      config.add_peer(
        "orders-safe",
        url: "http://orders-safe:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: [:system_read],
            denies: [:filesystem_write]
          }
        }
      )
      config.add_peer(
        "orders-risky",
        url: "http://orders-risky:4567",
        capabilities: [:orders],
        metadata: {
          policy: {
            allows: %i[system_read filesystem_write]
          }
        }
      )
      stub_alive("http://orders-safe:4567")
      stub_alive("http://orders-risky:4567")

      query = {
        all_of: [:orders],
        decision: {
          mode: :deny_risky,
          actions: [:system_read],
          risky: [:filesystem_write]
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-safe:4567")
    end

    it "can query over dynamic mesh freshness and confidence" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      config.add_peer(
        "orders-fresh",
        url: "http://orders-fresh:4567",
        capabilities: [:orders],
        metadata: { mesh: { observed_at: "2026-04-16T11:59:45Z", confidence: 0.92 } }
      )
      config.add_peer(
        "orders-stale",
        url: "http://orders-stale:4567",
        capabilities: [:orders],
        metadata: { mesh: { observed_at: "2026-04-16T11:58:00Z", confidence: 0.92 } }
      )
      stub_alive("http://orders-fresh:4567")
      stub_alive("http://orders-stale:4567")
      allow(Time).to receive(:now).and_return(now)

      query = {
        all_of: [:orders],
        metadata: {
          mesh: {
            freshness_seconds: { max: 30 },
            confidence: { min: 0.9 }
          }
        }
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-fresh:4567")
    end

    it "prefers the strongest alive peer when order_by is provided" do
      config.add_peer("orders-low", url: "http://orders-low:4567", capabilities: [:orders], metadata: { trust: { score: 0.90 }, load: { avg1m: 0.10 } })
      config.add_peer("orders-best", url: "http://orders-best:4567", capabilities: [:orders], metadata: { trust: { score: 0.98 }, load: { avg1m: 0.40 } })
      config.add_peer("orders-mid", url: "http://orders-mid:4567", capabilities: [:orders], metadata: { trust: { score: 0.95 }, load: { avg1m: 0.20 } })
      stub_alive("http://orders-low:4567")
      stub_alive("http://orders-best:4567")
      stub_alive("http://orders-mid:4567")

      query = {
        all_of: [:orders],
        order_by: [
          { metadata: "trust.score", direction: :desc },
          { metadata: "load.avg1m", direction: :asc }
        ]
      }

      expect(router.find_peer_for_query(query, deferred)).to eq("http://orders-best:4567")
    end

    it "round-robins only within the top-ranked peer tier" do
      config.add_peer("orders-top-a", url: "http://orders-top-a:4567", capabilities: [:orders], metadata: { trust: { score: 0.97 } })
      config.add_peer("orders-top-b", url: "http://orders-top-b:4567", capabilities: [:orders], metadata: { trust: { score: 0.97 } })
      config.add_peer("orders-low", url: "http://orders-low:4567", capabilities: [:orders], metadata: { trust: { score: 0.90 } })
      stub_alive("http://orders-top-a:4567")
      stub_alive("http://orders-top-b:4567")
      stub_alive("http://orders-low:4567")

      query = {
        all_of: [:orders],
        order_by: [
          { metadata: "trust.score", direction: :desc }
        ]
      }

      urls = 3.times.map { router.find_peer_for_query(query, deferred) }
      expect(urls).to all(satisfy { |url| %w[http://orders-top-a:4567 http://orders-top-b:4567].include?(url) })
      expect(urls).to include("http://orders-top-a:4567", "http://orders-top-b:4567")
    end

    it "find_peer_for round-robins across multiple alive peers" do
      config.add_peer("orders-1", url: "http://orders-1:4567", capabilities: [:orders])
      config.add_peer("orders-2", url: "http://orders-2:4567", capabilities: [:orders])
      stub_alive("http://orders-1:4567")
      stub_alive("http://orders-2:4567")
      urls = [
        router.find_peer_for(:orders, deferred),
        router.find_peer_for(:orders, deferred),
        router.find_peer_for(:orders, deferred)
      ]
      expect(urls).to include("http://orders-1:4567", "http://orders-2:4567")
    end

    it "prefers trusted peers over unknown peers when candidates are otherwise equal" do
      config.add_peer(
        "orders-trusted",
        url: "http://orders-trusted:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          }
        }
      )
      config.add_peer(
        "orders-unknown",
        url: "http://orders-unknown:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :unknown }
        }
      )
      stub_alive("http://orders-trusted:4567")
      stub_alive("http://orders-unknown:4567")
      allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 16, 12, 0, 0))

      urls = 3.times.map { router.find_peer_for(:orders, deferred) }

      expect(urls).to eq(["http://orders-trusted:4567"] * 3)
    end

    it "prefers fresher trusted attestations when query ranking is otherwise equal" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      config.add_peer(
        "orders-fresh",
        url: "http://orders-fresh:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          }
        }
      )
      config.add_peer(
        "orders-stale",
        url: "http://orders-stale:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:57:00Z"
          }
        }
      )
      stub_alive("http://orders-fresh:4567")
      stub_alive("http://orders-stale:4567")
      allow(Time).to receive(:now).and_return(now)

      expect(router.find_peer_for(:orders, deferred)).to eq("http://orders-fresh:4567")

      explanation = router.explain_peer_for(:orders)
      fresh = explanation[:peers].find { |peer| peer[:name] == "orders-fresh" }
      stale = explanation[:peers].find { |peer| peer[:name] == "orders-stale" }

      expect(fresh).to include(top_tier: true, selected: true)
      expect(stale).to include(top_tier: false)
    end

    it "prefers peers with trusted fresher governance checkpoints when trust is otherwise equal" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      config.add_peer(
        "orders-governed-fresh",
        url: "http://orders-governed-fresh:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          },
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:55Z"
          }
        }
      )
      config.add_peer(
        "orders-governed-stale",
        url: "http://orders-governed-stale:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          },
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:58:00Z"
          }
        }
      )
      stub_alive("http://orders-governed-fresh:4567")
      stub_alive("http://orders-governed-stale:4567")
      allow(Time).to receive(:now).and_return(now)

      expect(router.find_peer_for(:orders, deferred)).to eq("http://orders-governed-fresh:4567")

      explanation = router.explain_peer_for(:orders)
      fresh = explanation[:peers].find { |peer| peer[:name] == "orders-governed-fresh" }
      stale = explanation[:peers].find { |peer| peer[:name] == "orders-governed-stale" }

      expect(fresh).to include(top_tier: true, selected: true)
      expect(stale).to include(top_tier: false)
    end

    it "prefers healthier governance crest when governance trust and freshness are otherwise equal" do
      now = Time.utc(2026, 4, 16, 12, 0, 0)
      config.add_peer(
        "orders-governed-healthy",
        url: "http://orders-governed-healthy:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          },
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:55Z",
            blocked_events: 1,
            applied_events: 5
          }
        }
      )
      config.add_peer(
        "orders-governed-unhealthy",
        url: "http://orders-governed-unhealthy:4567",
        capabilities: [:orders],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            observed_at: "2026-04-16T11:59:50Z"
          },
          mesh_governance: {
            trust: { status: :trusted },
            checkpointed_at: "2026-04-16T11:59:55Z",
            blocked_events: 4,
            applied_events: 1
          }
        }
      )
      stub_alive("http://orders-governed-healthy:4567")
      stub_alive("http://orders-governed-unhealthy:4567")
      allow(Time).to receive(:now).and_return(now)

      expect(router.find_peer_for(:orders, deferred)).to eq("http://orders-governed-healthy:4567")

      explanation = router.explain_peer_for(:orders)
      healthy = explanation[:peers].find { |peer| peer[:name] == "orders-governed-healthy" }
      unhealthy = explanation[:peers].find { |peer| peer[:name] == "orders-governed-unhealthy" }

      expect(healthy).to include(top_tier: true, selected: true)
      expect(unhealthy).to include(top_tier: false)
    end

    it "resolve_pinned raises IncidentError for unknown peer" do
      expect {
        router.resolve_pinned("audit-node")
      }.to raise_error(Igniter::Cluster::Mesh::IncidentError) { |e|
        expect(e.peer_name).to eq("audit-node")
        expect(e.context[:routing_trace]).to include(
          routing_mode: :pinned,
          peer_name: "audit-node",
          known: false,
          reasons: [:unknown_peer]
        )
      }
    end

    it "resolve_pinned raises IncidentError when peer is down" do
      config.add_peer("audit-node", url: "http://audit:4567", capabilities: [:audit])
      stub_dead("http://audit:4567")
      expect {
        router.resolve_pinned("audit-node")
      }.to raise_error(Igniter::Cluster::Mesh::IncidentError) { |e|
        expect(e.peer_name).to eq("audit-node")
        expect(e.context[:routing_trace]).to include(
          routing_mode: :pinned,
          peer_name: "audit-node",
          known: true,
          selected_url: "http://audit:4567",
          reachable: false,
          reasons: [:unreachable]
        )
      }
    end

    it "resolve_pinned returns URL when peer is alive" do
      config.add_peer("audit-node", url: "http://audit:4567", capabilities: [:audit])
      stub_alive("http://audit:4567")
      expect(router.resolve_pinned("audit-node")).to eq("http://audit:4567")
    end

    it "caches health checks within TTL" do
      config.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
      client = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
      allow(Igniter::Server::Client).to receive(:new).with("http://orders:4567", timeout: 3).and_return(client)

      router.find_peer_for(:orders, deferred)
      router.find_peer_for(:orders, deferred)

      # health should only be called once (second call uses cache)
      expect(client).to have_received(:health).once
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # RemoteNode routing_mode
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Model::RemoteNode do
    def make_node(**opts)
      Igniter::Model::RemoteNode.new(
        id: "test:1", name: :x, contract_name: "Foo",
        input_mapping: {}, **opts
      )
    end

    it "defaults to :static routing_mode when node_url is set" do
      expect(make_node(node_url: "http://x:4567").routing_mode).to eq(:static)
    end

    it "is :capability when capability: is set" do
      expect(make_node(capability: :orders).routing_mode).to eq(:capability)
    end

    it "is :capability when capability_query: is set" do
      expect(make_node(capability_query: { all_of: [:orders], tags: [:linux] }).routing_mode).to eq(:capability)
    end

    it "is :pinned when pinned_to: is set" do
      expect(make_node(pinned_to: "audit-node").routing_mode).to eq(:pinned)
    end

    it "pinned_to takes precedence over capability" do
      expect(make_node(capability: :orders, pinned_to: "audit-node").routing_mode).to eq(:pinned)
    end

    it "stores capability as symbol" do
      expect(make_node(capability: "orders").capability).to eq(:orders)
    end

    it "stores capability_query as normalized hash" do
      expect(make_node(capability_query: { all_of: ["orders"], tags: ["linux"] }).capability_query)
        .to eq({ all_of: [:orders], tags: [:linux] })
    end

    it "preserves metadata strings while normalizing policy and capability keys" do
      node = make_node(
        capability_query: {
          all_of: ["orders"],
          metadata: { region: "eu-central" },
          policy: { permits: ["system_read"] }
        }
      )

      expect(node.capability_query).to eq(
        all_of: [:orders],
        metadata: { region: "eu-central" },
        policy: { permits: [:system_read] }
      )
    end

    it "normalizes decision keys inside capability_query" do
      node = make_node(
        capability_query: {
          all_of: ["orders"],
          decision: { mode: "approval_ok", actions: ["shell_exec"], risky: ["filesystem_write"] }
        }
      )

      expect(node.capability_query).to eq(
        all_of: [:orders],
        decision: { mode: :approval_ok, actions: [:shell_exec], risky: [:filesystem_write] }
      )
    end

    it "normalizes trust keys inside capability_query" do
      node = make_node(
        capability_query: {
          all_of: ["orders"],
          trust: { identity: "trusted", attestation: "trusted" }
        }
      )

      expect(node.capability_query).to eq(
        all_of: [:orders],
        trust: { identity: :trusted, attestation: :trusted }
      )
    end

    it "normalizes governance keys inside capability_query" do
      node = make_node(
        capability_query: {
          all_of: ["orders"],
          governance: { trust: "trusted", latest_type: "routing_plan_applied" }
        }
      )

      expect(node.capability_query).to eq(
        all_of: [:orders],
        governance: { trust: :trusted, latest_type: :routing_plan_applied }
      )
    end

    it "stores pinned_to as string" do
      expect(make_node(pinned_to: :audit_node).pinned_to).to eq("audit_node")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DSL
  # ─────────────────────────────────────────────────────────────────────────────
  describe "remote: DSL" do
    let(:builder) { Igniter::DSL::ContractBuilder.new(name: "TestContract") }

    it "raises CompileError when neither node:, capability:, query:, nor pinned_to: given" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {})
      }.to raise_error(Igniter::CompileError, /requires a node/)
    end

    it "raises CompileError if query: and pinned_to: both given" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, query: { all_of: [:orders] }, pinned_to: "audit-node")
      }.to raise_error(Igniter::CompileError, /mutually exclusive/)
    end

    it "raises CompileError when policy: is given without capability: or query:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, policy: { permits: [:system_read] })
      }.to raise_error(Igniter::CompileError, /policy: requires capability: or query:/)
    end

    it "raises CompileError when governance: is given without capability: or query:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, governance: { trust: :trusted })
      }.to raise_error(Igniter::CompileError, /governance: requires capability: or query:/)
    end

    it "raises CompileError when trust: is given without capability: or query:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, trust: { identity: :trusted })
      }.to raise_error(Igniter::CompileError, /trust: requires capability: or query:/)
    end

    it "raises CompileError when trust: is combined with pinned_to:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, trust: { identity: :trusted }, pinned_to: "audit-node")
      }.to raise_error(Igniter::CompileError, /trust: cannot be combined with pinned_to:/)
    end

    it "raises CompileError when governance: duplicates query governance" do
      expect {
        builder.remote(
          :x,
          contract: "Foo",
          query: { all_of: [:orders], governance: { trust: :trusted } },
          governance: { latest_type: :routing_plan_applied },
          inputs: {}
        )
      }.to raise_error(Igniter::CompileError, /governance: duplicates query\[:governance\]/)
    end

    it "raises CompileError when governance: is combined with pinned_to:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, governance: { trust: :trusted }, pinned_to: "audit-node")
      }.to raise_error(Igniter::CompileError, /governance: cannot be combined with pinned_to:/)
    end

    it "raises CompileError when policy: is combined with pinned_to:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, policy: { permits: [:system_read] }, pinned_to: "audit-node")
      }.to raise_error(Igniter::CompileError, /policy: cannot be combined with pinned_to:/)
    end

    it "raises CompileError when decision: is given without capability: or query:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, decision: { mode: :approval_ok, actions: [:shell_exec] })
      }.to raise_error(Igniter::CompileError, /decision: requires capability: or query:/)
    end

    it "raises CompileError when decision: is combined with pinned_to:" do
      expect {
        builder.remote(:x, contract: "Foo", inputs: {}, decision: { mode: :approval_ok, actions: [:shell_exec] }, pinned_to: "audit-node")
      }.to raise_error(Igniter::CompileError, /decision: cannot be combined with pinned_to:/)
    end

    it "accepts static routing with node:" do
      builder.remote(:x, contract: "Foo", node: "http://x:4567", inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:static)
    end

    it "accepts capability: routing without node:" do
      builder.remote(:x, contract: "Foo", capability: :orders, inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:capability)
      expect(node.capability).to eq(:orders)
    end

    it "accepts query: routing without node:" do
      builder.remote(:x, contract: "Foo", query: { all_of: [:orders], tags: [:linux] }, inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:capability)
      expect(node.capability_query).to eq({ all_of: [:orders], tags: [:linux] })
    end

    it "accepts capability: with policy: by lifting both into a capability query" do
      builder.remote(:x, contract: "Foo", capability: :orders, policy: { permits: [:system_read] }, inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:capability)
      expect(node.capability).to be_nil
      expect(node.capability_query).to eq({ all_of: [:orders], policy: { permits: [:system_read] } })
    end

    it "accepts capability: with trust: by lifting both into a capability query" do
      builder.remote(:x, contract: "Foo", capability: :orders, trust: { identity: :trusted }, inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:capability)
      expect(node.capability).to be_nil
      expect(node.capability_query).to eq({ all_of: [:orders], trust: { identity: :trusted } })
    end

    it "accepts query: with trust: by merging trust into the capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        query: { all_of: [:orders], metadata: { region: "eu-central" } },
        trust: { identity: :trusted, attestation: :trusted },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.capability_query).to eq(
        all_of: [:orders],
        metadata: { region: "eu-central" },
        trust: { identity: :trusted, attestation: :trusted }
      )
    end

    it "accepts capability: with governance: by lifting both into a capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        capability: :orders,
        governance: { trust: :trusted, latest_type: :routing_plan_applied },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:capability)
      expect(node.capability).to be_nil
      expect(node.capability_query).to eq(
        all_of: [:orders],
        governance: { trust: :trusted, latest_type: :routing_plan_applied }
      )
    end

    it "accepts query: with governance: by merging governance into the capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        query: { all_of: [:orders], metadata: { region: "eu-central" } },
        governance: { trust: :trusted, blocked_events: { max: 1 } },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.capability_query).to eq(
        all_of: [:orders],
        metadata: { region: "eu-central" },
        governance: { trust: :trusted, blocked_events: { max: 1 } }
      )
    end

    it "accepts query: with policy: by merging policy into the capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        query: { all_of: [:orders], metadata: { region: "eu-central" } },
        policy: { approvable: [:shell_exec] },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.capability_query).to eq(
        all_of: [:orders],
        metadata: { region: "eu-central" },
        policy: { approvable: [:shell_exec] }
      )
    end

    it "accepts capability: with decision: by lifting both into a capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        capability: :orders,
        decision: { mode: :approval_ok, actions: [:shell_exec] },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.capability).to be_nil
      expect(node.capability_query).to eq(
        all_of: [:orders],
        decision: { mode: :approval_ok, actions: [:shell_exec] }
      )
    end

    it "accepts query: with decision: by merging decision into the capability query" do
      builder.remote(
        :x,
        contract: "Foo",
        query: { all_of: [:orders] },
        decision: { mode: :deny_risky, actions: [:system_read], risky: [:filesystem_write] },
        inputs: {}
      )
      node = builder.instance_variable_get(:@nodes).last
      expect(node.capability_query).to eq(
        all_of: [:orders],
        decision: { mode: :deny_risky, actions: [:system_read], risky: [:filesystem_write] }
      )
    end

    it "accepts pinned_to: routing without node:" do
      builder.remote(:x, contract: "Foo", pinned_to: "audit-node", inputs: {})
      node = builder.instance_variable_get(:@nodes).last
      expect(node.routing_mode).to eq(:pinned)
      expect(node.pinned_to).to eq("audit-node")
    end
  end


  # ─────────────────────────────────────────────────────────────────────────────
  # RemoteValidator
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Compiler::Validators::RemoteValidator do
    def compile_with_remote(**opts)
      Class.new(Igniter::Contract) do
        define do
          input :x
          remote :result, contract: "Foo", inputs: { x: :x }, **opts
          output :result
        end
      end
    end

    it "accepts static routing with a valid http:// URL" do
      expect { compile_with_remote(node: "http://peer:4567") }.not_to raise_error
    end

    it "rejects static routing with a bad URL" do
      expect {
        compile_with_remote(node: "not-a-url")
      }.to raise_error(Igniter::ValidationError, /invalid node/)
    end

    it "skips URL validation for capability: routing" do
      expect { compile_with_remote(capability: :orders) }.not_to raise_error
    end

    it "skips URL validation for query: routing" do
      expect { compile_with_remote(query: { all_of: [:orders], tags: [:linux] }) }.not_to raise_error
    end

    it "skips URL validation for pinned_to: routing" do
      expect { compile_with_remote(pinned_to: "audit-node") }.not_to raise_error
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Server::Config
  # ─────────────────────────────────────────────────────────────────────────────
  describe Igniter::Server::Config do
    subject(:config) { described_class.new }

    it "defaults peer_name to nil" do
      expect(config.peer_name).to be_nil
    end

    it "defaults peer_capabilities to empty array" do
      expect(config.peer_capabilities).to eq([])
    end

    it "defaults peer_tags to empty array" do
      expect(config.peer_tags).to eq([])
    end

    it "peer_name is assignable" do
      config.peer_name = "api-node"
      expect(config.peer_name).to eq("api-node")
    end

    it "peer_capabilities is assignable" do
      config.peer_capabilities = [:api, :search]
      expect(config.peer_capabilities).to eq(%i[api search])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # ManifestHandler
  # ─────────────────────────────────────────────────────────────────────────────
  describe "GET /v1/manifest" do
    let(:registry) do
      r = Igniter::Server::Registry.new
      r.register("ProcessOrder", Class.new(Igniter::Contract))
      r
    end
    let(:store) { Igniter::Runtime::Stores::MemoryStore.new }
    let(:server_config) do
      cfg = Igniter::Server::Config.new
      cfg.peer_name         = "orders-node"
      cfg.peer_capabilities = [:orders, :inventory]
      cfg.peer_tags         = [:linux]
      cfg.peer_metadata     = { "zone" => "eu-1" }
      cfg
    end
    let(:handler) { Igniter::Server::Handlers::ManifestHandler.new(registry, store, config: server_config) }

    it "returns 200" do
      result = handler.call(params: {}, body: {})
      expect(result[:status]).to eq(200)
    end

    it "includes peer_name" do
      result = handler.call(params: {}, body: {})
      body = JSON.parse(result[:body])
      expect(body["peer_name"]).to eq("orders-node")
      expect(body["node_id"]).to eq("orders-node")
    end

    it "includes capabilities as strings" do
      result = handler.call(params: {}, body: {})
      body = JSON.parse(result[:body])
      expect(body["capabilities"]).to contain_exactly("orders", "inventory")
    end

    it "includes tags and metadata" do
      result = handler.call(params: {}, body: {})
      body = JSON.parse(result[:body])
      expect(body["tags"]).to eq(["linux"])
      expect(body["metadata"]).to include("zone" => "eu-1")
      expect(body.dig("metadata", "mesh")).to include(
        "confidence" => 1.0,
        "hops" => 0,
        "origin" => "orders-node"
      )
    end

    it "includes contract names" do
      result = handler.call(params: {}, body: {})
      body = JSON.parse(result[:body])
      expect(body["contracts"]).to include("ProcessOrder")
    end

    it "includes url" do
      result = handler.call(params: {}, body: {})
      body = JSON.parse(result[:body])
      expect(body["url"]).to match(/http:\/\//)
      expect(body["signature"]).to be_a(String)
      expect(body["public_key"]).to include("BEGIN PUBLIC KEY")
      expect(body["signed_at"]).to be_a(String)
      expect(body["capability_attestation"]).to include(
        "node_id" => "orders-node",
        "peer_name" => "orders-node",
        "url" => kind_of(String),
        "signature" => kind_of(String)
      )
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Client#get_manifest
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Igniter::Server::Client#manifest" do
    let(:client) { Igniter::Server::Client.new("http://peer:4567") }

    before do
      response = instance_double(Net::HTTPResponse,
                                 is_a?: true,
                                 code: "200",
                                 body: JSON.generate({
                                   "peer_name" => "orders-node",
                                   "node_id" => "orders-node",
                                   "algorithm" => "rsa-sha256",
                                   "public_key" => "pem",
                                   "capabilities" => %w[orders inventory],
                                   "tags" => %w[linux],
                                   "metadata" => { "zone" => "eu-1" },
                                   "contracts" => ["ProcessOrder"],
                                    "url" => "http://orders:4567",
                                   "capability_attestation" => {
                                     "node_id" => "orders-node",
                                     "peer_name" => "orders-node",
                                     "signature" => "attestation123"
                                   },
                                   "signed_at" => "2026-04-17T10:00:00Z",
                                   "signature" => "abc123"
                                 }))
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:request).and_return(response)
    end

    it "returns symbolized peer manifest" do
      manifest = client.manifest
      expect(manifest[:peer_name]).to eq("orders-node")
      expect(manifest[:node_id]).to eq("orders-node")
      expect(manifest[:capabilities]).to eq(%i[orders inventory])
      expect(manifest[:tags]).to eq([:linux])
      expect(manifest[:metadata]).to eq({ "zone" => "eu-1" })
      expect(manifest[:contracts]).to include("ProcessOrder")
      expect(manifest[:url]).to eq("http://orders:4567")
      expect(manifest[:signature]).to eq("abc123")
      expect(manifest[:capability_attestation]).to include(
        "node_id" => "orders-node",
        "signature" => "attestation123"
      )
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Resolver integration
  # ─────────────────────────────────────────────────────────────────────────────
  describe "Resolver integration" do
    around do |example|
      previous_adapter = Igniter::Runtime.remote_adapter
      Igniter::Cluster.activate_remote_adapter!
      example.run
      Igniter::Runtime.remote_adapter = previous_adapter
    end

    after { Igniter::Cluster::Mesh.reset! }

    def mock_remote_response(url, contract_name, outputs: { result: 42 })
      client = instance_double(Igniter::Server::Client)
      allow(Igniter::Server::Client).to receive(:new).with(url, timeout: 30).and_return(client)
      allow(client).to receive(:execute).with(contract_name, inputs: anything)
                                        .and_return({ status: :succeeded, outputs: outputs })
    end

    context "with capability: routing" do
      let(:contract_class) do
        Class.new(Igniter::Contract) do
          define do
            input :order_id
            remote :order_result,
                   contract: "ProcessOrder",
                   capability: :orders,
                   inputs: { id: :order_id }
            output :order_result
          end
        end
      end

      it "defers (node :pending) when no alive peer for capability" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
        end

        # Peer health check fails
        dead_client = instance_double(Igniter::Server::Client)
        allow(Igniter::Server::Client).to receive(:new).with("http://orders:4567", timeout: 3).and_return(dead_client)
        allow(dead_client).to receive(:health).and_raise(Igniter::Server::Client::ConnectionError, "refused")

        contract = contract_class.new(order_id: 1)
        begin
          contract.resolve_all
        rescue Igniter::Error
          nil
        end

        order_state = contract.execution.cache.fetch(:order_result)
        expect(order_state).to be_pending
      end

      it "succeeds when an alive peer is available" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer("orders-node", url: "http://orders:4567", capabilities: [:orders])
        end

        alive_client = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
        allow(Igniter::Server::Client).to receive(:new).with("http://orders:4567", timeout: 3).and_return(alive_client)
        mock_remote_response("http://orders:4567", "ProcessOrder", outputs: { result: 99 })

        contract = contract_class.new(order_id: 42)
        contract.resolve_all
        expect(contract.result.order_result).to eq({ result: 99 })
      end
    end

    context "with pinned_to: routing" do
      let(:contract_class) do
        Class.new(Igniter::Contract) do
          define do
            input :event
            remote :audit,
                   contract: "WriteAudit",
                   pinned_to: "audit-node",
                   inputs: { event: :event }
            output :audit
          end
        end
      end

      it "fails (node :failed) with IncidentError when pinned peer is down" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer("audit-node", url: "http://audit:4567", capabilities: [:audit])
        end

        dead_client = instance_double(Igniter::Server::Client)
        allow(Igniter::Server::Client).to receive(:new).with("http://audit:4567", timeout: 3).and_return(dead_client)
        allow(dead_client).to receive(:health).and_raise(Igniter::Server::Client::ConnectionError, "refused")

        contract = contract_class.new(event: "created")
        begin
          contract.resolve_all
        rescue Igniter::Error
          nil
        end

        audit_state = contract.execution.cache.fetch(:audit)
        expect(audit_state).to be_failed
        expect(audit_state.error).to be_a(Igniter::Cluster::Mesh::IncidentError)
      end

      it "succeeds when pinned peer is alive" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer("audit-node", url: "http://audit:4567", capabilities: [:audit])
        end

        alive_client = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
        allow(Igniter::Server::Client).to receive(:new).with("http://audit:4567", timeout: 3).and_return(alive_client)
        mock_remote_response("http://audit:4567", "WriteAudit", outputs: { logged: true })

        contract = contract_class.new(event: "created")
        contract.resolve_all
        expect(contract.result.audit).to eq({ logged: true })
      end
    end

    context "with query: routing" do
      let(:contract_class) do
        Class.new(Igniter::Contract) do
          define do
            input :order_id
            remote :order_result,
                   contract: "ProcessOrder",
                   query: { all_of: [:orders], tags: [:linux] },
                   inputs: { id: :order_id }
            output :order_result
          end
        end
      end

      it "routes only to peers matching the full query" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer("orders-linux", url: "http://orders-linux:4567", capabilities: [:orders], tags: [:linux])
          c.add_peer("orders-mac", url: "http://orders-mac:4567", capabilities: [:orders], tags: [:darwin])
        end

        alive_linux = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
        alive_mac = instance_double(Igniter::Server::Client, health: { "status" => "ok" })
        allow(Igniter::Server::Client).to receive(:new).with("http://orders-linux:4567", timeout: 3).and_return(alive_linux)
        allow(Igniter::Server::Client).to receive(:new).with("http://orders-mac:4567", timeout: 3).and_return(alive_mac)
        mock_remote_response("http://orders-linux:4567", "ProcessOrder", outputs: { result: 100 })

        contract = contract_class.new(order_id: 42)
        contract.resolve_all
        expect(contract.result.order_result).to eq({ result: 100 })
      end
    end
  end
end
