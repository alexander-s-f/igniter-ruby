# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter::Cluster Governance Admission Workflow (Phase 8)" do
  let(:identity_a)   { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "peer-a") }
  let(:identity_b)   { Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "peer-b") }
  let(:trust_store)  { Igniter::Cluster::Trust::TrustStore.new }
  let(:trail)        { Igniter::Cluster::Governance::Trail.new }

  # ── AdmissionRequest ──────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::AdmissionRequest do
    subject(:req) do
      described_class.build(
        peer_name:    "node-a",
        node_id:      "peer-a",
        public_key:   identity_a.public_key_pem,
        capabilities: [:rag, :database],
        justification: "joining cluster"
      )
    end

    it "has a unique request_id (UUID)" do
      expect(req.request_id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "stores capabilities as symbols" do
      expect(req.capabilities).to eq(%i[rag database])
    end

    it "computes a fingerprint from the public key" do
      expect(req.fingerprint).to be_a(String)
      expect(req.fingerprint.length).to eq(24)
    end

    it "two requests from the same identity have the same fingerprint" do
      r2 = described_class.build(peer_name: "node-a", node_id: "peer-a",
                                  public_key: identity_a.public_key_pem)
      expect(req.fingerprint).to eq(r2.fingerprint)
    end

    it "serializes to hash" do
      h = req.to_h
      expect(h[:peer_name]).to eq("node-a")
      expect(h[:capabilities]).to eq(%i[rag database])
      expect(h[:fingerprint]).to eq(req.fingerprint)
    end

    it "is frozen" do
      expect(req).to be_frozen
    end

    describe "url field" do
      it "defaults url to empty string when not provided" do
        expect(req.url).to eq("")
      end

      it "stores a provided url" do
        r = described_class.build(peer_name: "n", node_id: "n",
                                   public_key: identity_a.public_key_pem,
                                   url: "http://node-a:4567")
        expect(r.url).to eq("http://node-a:4567")
      end

      it "routable? is false when url is empty" do
        expect(req.routable?).to be false
      end

      it "routable? is true when url is present" do
        r = described_class.build(peer_name: "n", node_id: "n",
                                   public_key: identity_a.public_key_pem,
                                   url: "http://node-a:4567")
        expect(r.routable?).to be true
      end

      it "includes url in to_h" do
        r = described_class.build(peer_name: "n", node_id: "n",
                                   public_key: identity_a.public_key_pem,
                                   url: "http://node-a:4567")
        expect(r.to_h[:url]).to eq("http://node-a:4567")
      end
    end
  end

  # ── AdmissionDecision ─────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::AdmissionDecision do
    let(:request) do
      Igniter::Cluster::Governance::AdmissionRequest.build(
        peer_name: "n", node_id: "n", public_key: identity_a.public_key_pem
      )
    end

    it "admitted? returns true for :admitted outcome" do
      d = described_class.build(request: request, outcome: :admitted)
      expect(d).to be_admitted
    end

    it "rejected? returns true for :rejected outcome" do
      d = described_class.build(request: request, outcome: :rejected)
      expect(d).to be_rejected
    end

    it "pending_approval? returns true for :pending_approval outcome" do
      d = described_class.build(request: request, outcome: :pending_approval)
      expect(d).to be_pending_approval
    end

    it "already_trusted? returns true for :already_trusted outcome" do
      d = described_class.build(request: request, outcome: :already_trusted)
      expect(d).to be_already_trusted
    end

    it "serializes to hash" do
      d = described_class.build(request: request, outcome: :admitted, rationale: "known key")
      h = d.to_h
      expect(h[:outcome]).to eq(:admitted)
      expect(h[:rationale]).to eq("known key")
    end
  end

  # ── AdmissionPolicy ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::AdmissionPolicy do
    let(:fp_a) { Igniter::Cluster::Governance::AdmissionRequest
                   .build(peer_name: "a", node_id: "peer-a", public_key: identity_a.public_key_pem)
                   .fingerprint }

    def make_request(node_id:, public_key:, capabilities: [])
      Igniter::Cluster::Governance::AdmissionRequest.build(
        peer_name: node_id, node_id: node_id, public_key: public_key, capabilities: capabilities
      )
    end

    context "default policy (require_approval: true, no known_keys)" do
      subject(:policy) { described_class.new }

      it "returns :pending_approval for unknown peers" do
        req = make_request(node_id: "peer-a", public_key: identity_a.public_key_pem)
        expect(policy.evaluate(req, trust_store)).to eq(:pending_approval)
      end

      it "returns :already_trusted when node_id is in TrustStore" do
        trust_store.add("peer-a", public_key: identity_a.public_key_pem, label: "existing")
        req = make_request(node_id: "peer-a", public_key: identity_a.public_key_pem)
        expect(policy.evaluate(req, trust_store)).to eq(:already_trusted)
      end
    end

    context "with known_keys" do
      subject(:policy) { described_class.new(known_keys: { "peer-a" => fp_a }) }

      it "returns :admitted for matching fingerprint" do
        req = make_request(node_id: "peer-a", public_key: identity_a.public_key_pem)
        expect(policy.evaluate(req, trust_store)).to eq(:admitted)
      end

      it "returns :pending_approval when fingerprint does not match" do
        req = make_request(node_id: "peer-a", public_key: identity_b.public_key_pem)
        expect(policy.evaluate(req, trust_store)).to eq(:pending_approval)
      end
    end

    context "with forbidden_capabilities" do
      subject(:policy) { described_class.new(forbidden_capabilities: [:admin]) }

      it "returns :rejected when request includes forbidden capability" do
        req = make_request(node_id: "peer-b", public_key: identity_b.public_key_pem,
                           capabilities: [:admin, :rag])
        expect(policy.evaluate(req, trust_store)).to eq(:rejected)
      end

      it "returns :pending_approval when no forbidden capability present" do
        req = make_request(node_id: "peer-b", public_key: identity_b.public_key_pem,
                           capabilities: [:rag])
        expect(policy.evaluate(req, trust_store)).to eq(:pending_approval)
      end
    end

    context "open policy (require_approval: false)" do
      subject(:policy) { described_class.new(require_approval: false) }

      it "returns :admitted for unknown peers" do
        req = make_request(node_id: "peer-b", public_key: identity_b.public_key_pem)
        expect(policy.evaluate(req, trust_store)).to eq(:admitted)
      end
    end
  end

  # ── AdmissionQueue ────────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::AdmissionQueue do
    subject(:queue) { described_class.new }

    def make_request(node_id = "peer-a")
      Igniter::Cluster::Governance::AdmissionRequest.build(
        peer_name: node_id, node_id: node_id, public_key: identity_a.public_key_pem
      )
    end

    it "starts empty" do
      expect(queue.empty?).to be true
    end

    it "enqueue adds a request" do
      queue.enqueue(make_request)
      expect(queue.size).to eq(1)
    end

    it "pending returns all queued requests" do
      r = make_request
      queue.enqueue(r)
      expect(queue.pending).to include(r)
    end

    it "find retrieves by request_id" do
      r = make_request
      queue.enqueue(r)
      expect(queue.find(r.request_id)).to eq(r)
    end

    it "dequeue removes and returns the request" do
      r = make_request
      queue.enqueue(r)
      removed = queue.dequeue(r.request_id)
      expect(removed).to eq(r)
      expect(queue.empty?).to be true
    end

    it "dequeue returns nil for unknown id" do
      expect(queue.dequeue("ghost")).to be_nil
    end

    describe "#expire_stale!" do
      it "removes requests older than ttl" do
        r = Igniter::Cluster::Governance::AdmissionRequest.build(
          peer_name: "old", node_id: "old", public_key: identity_a.public_key_pem,
          requested_at: (Time.now.utc - 7200).iso8601
        )
        queue.enqueue(r)
        expired = queue.expire_stale!(3600)
        expect(expired).to include(r)
        expect(queue.empty?).to be true
      end

      it "keeps requests within ttl" do
        r = make_request
        queue.enqueue(r)
        expired = queue.expire_stale!(3600)
        expect(expired).to be_empty
        expect(queue.size).to eq(1)
      end
    end
  end

  # ── AdmissionWorkflow ─────────────────────────────────────────────────────────

  describe Igniter::Cluster::Governance::AdmissionWorkflow do
    def make_config(policy: nil)
      cfg = Igniter::Cluster::Mesh::Config.new
      cfg.trust_store     = Igniter::Cluster::Trust::TrustStore.new
      cfg.governance_trail = Igniter::Cluster::Governance::Trail.new
      cfg.admission_policy = policy if policy
      cfg
    end

    subject(:workflow) { described_class.new(config: config) }

    context "default policy (require_approval: true)" do
      let(:config) { make_config }

      it "returns :pending_approval for an unknown peer" do
        decision = workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(decision).to be_pending_approval
      end

      it "enqueues the request for later approval" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(config.admission_queue.size).to eq(1)
      end

      it "records :admission_requested in the governance trail" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_requested)
      end

      it "records :admission_pending in the trail" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_pending)
      end
    end

    context "auto-admit via known_keys" do
      let(:fp_b) do
        Igniter::Cluster::Governance::AdmissionRequest
          .build(peer_name: "b", node_id: "peer-b", public_key: identity_b.public_key_pem)
          .fingerprint
      end
      let(:policy) do
        Igniter::Cluster::Governance::AdmissionPolicy.new(
          known_keys: { "peer-b" => fp_b }
        )
      end
      let(:config) { make_config(policy: policy) }

      it "returns :admitted for known key" do
        decision = workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(decision).to be_admitted
      end

      it "adds the peer to the trust store" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(config.trust_store.entry_for("peer-b")).not_to be_nil
      end

      it "records :admission_admitted in the trail" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_admitted)
      end

      it "does not add to pending queue" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(config.admission_queue&.size.to_i).to eq(0)
      end

      it "registers peer in PeerRegistry when url is provided" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567"
        )
        peer = config.peer_registry.peer_named("node-b")
        expect(peer).not_to be_nil
        expect(peer.url).to eq("http://node-b:4567")
      end

      it "peer in registry has correct capabilities" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567",
          capabilities: [:rag, :database]
        )
        peer = config.peer_registry.peer_named("node-b")
        expect(peer.capabilities).to include(:rag, :database)
      end

      it "does NOT register in PeerRegistry when url is absent" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
        expect(config.peer_registry.peer_named("node-b")).to be_nil
      end

      it "admitted peer observation is trust-aware" do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567"
        )
        obs = config.peer_registry.observation_for("node-b")
        expect(obs).to be_trusted
      end
    end

    context "rejection by forbidden capability" do
      let(:policy) do
        Igniter::Cluster::Governance::AdmissionPolicy.new(
          forbidden_capabilities: [:admin]
        )
      end
      let(:config) { make_config(policy: policy) }

      it "returns :rejected" do
        decision = workflow.request_admission(
          peer_name: "bad-node", node_id: "peer-bad",
          public_key: identity_a.public_key_pem,
          capabilities: [:admin]
        )
        expect(decision).to be_rejected
      end

      it "records :admission_rejected in the trail" do
        workflow.request_admission(
          peer_name: "bad-node", node_id: "peer-bad",
          public_key: identity_a.public_key_pem,
          capabilities: [:admin]
        )
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_rejected)
      end
    end

    context "already trusted" do
      let(:config) { make_config }

      before do
        config.trust_store.add("peer-a", public_key: identity_a.public_key_pem, label: "bootstrap")
      end

      it "returns :already_trusted" do
        decision = workflow.request_admission(
          peer_name: "node-a", node_id: "peer-a", public_key: identity_a.public_key_pem
        )
        expect(decision).to be_already_trusted
      end

      it "does not add a duplicate trail event" do
        workflow.request_admission(
          peer_name: "node-a", node_id: "peer-a", public_key: identity_a.public_key_pem
        )
        # Only :admission_requested recorded, no :admission_admitted for idempotent case
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_requested)
        expect(types).not_to include(:admission_admitted)
      end
    end

    describe "#approve_pending!" do
      let(:config) { make_config }

      context "without url" do
        before do
          workflow.request_admission(
            peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
          )
        end

        it "returns :admitted decision" do
          request_id = config.admission_queue.pending.first.request_id
          decision = workflow.approve_pending!(request_id)
          expect(decision).to be_admitted
        end

        it "adds peer to trust store" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.approve_pending!(request_id)
          expect(config.trust_store.entry_for("peer-b")).not_to be_nil
        end

        it "removes from pending queue" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.approve_pending!(request_id)
          expect(config.admission_queue.empty?).to be true
        end

        it "records :admission_approved in the trail" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.approve_pending!(request_id)
          types = config.governance_trail.events.map { |e| e[:type] }
          expect(types).to include(:admission_approved)
        end

        it "returns :rejected when request_id is unknown" do
          decision = workflow.approve_pending!("nonexistent-uuid")
          expect(decision).to be_rejected
        end
      end

      context "with url — auto-registration on operator approval" do
        before do
          workflow.request_admission(
            peer_name: "node-b", node_id: "peer-b",
            public_key: identity_b.public_key_pem,
            url: "http://node-b:4567",
            capabilities: [:database]
          )
        end

        it "registers peer in PeerRegistry after operator approval" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.approve_pending!(request_id)
          expect(config.peer_registry.peer_named("node-b")).not_to be_nil
        end

        it "registered peer is routable via observations" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.approve_pending!(request_id)
          obs = config.peer_registry.observations
          expect(obs.map(&:name)).to include("node-b")
        end

        it "does not register when rejected" do
          request_id = config.admission_queue.pending.first.request_id
          workflow.reject_pending!(request_id)
          expect(config.peer_registry.peer_named("node-b")).to be_nil
        end
      end
    end

    describe "#reject_pending!" do
      let(:config) { make_config }

      before do
        workflow.request_admission(
          peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
        )
      end

      it "returns :rejected decision" do
        request_id = config.admission_queue.pending.first.request_id
        decision = workflow.reject_pending!(request_id, reason: "too risky")
        expect(decision).to be_rejected
      end

      it "removes from pending queue" do
        request_id = config.admission_queue.pending.first.request_id
        workflow.reject_pending!(request_id)
        expect(config.admission_queue.empty?).to be true
      end

      it "does NOT add peer to trust store" do
        request_id = config.admission_queue.pending.first.request_id
        workflow.reject_pending!(request_id)
        expect(config.trust_store.entry_for("peer-b")).to be_nil
      end

      it "records :admission_rejected in the trail" do
        request_id = config.admission_queue.pending.first.request_id
        workflow.reject_pending!(request_id)
        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_rejected)
      end
    end

    describe "#expire_stale!" do
      let(:config) { make_config }

      it "expires old pending requests and records in trail" do
        old_request = Igniter::Cluster::Governance::AdmissionRequest.build(
          peer_name: "old", node_id: "old-node",
          public_key: identity_b.public_key_pem,
          requested_at: (Time.now.utc - 7200).iso8601
        )
        config.admission_queue ||= Igniter::Cluster::Governance::AdmissionQueue.new
        config.admission_queue.enqueue(old_request)

        expired = workflow.expire_stale!
        expect(expired.size).to eq(1)
        expect(expired.first).to be_rejected

        types = config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:admission_expired)
      end
    end
  end

  # ── Mesh convenience methods ──────────────────────────────────────────────────

  describe "Mesh admission convenience methods" do
    before { Igniter::Cluster::Mesh.reset! }
    after  { Igniter::Cluster::Mesh.reset! }

    let(:fp_b) do
      Igniter::Cluster::Governance::AdmissionRequest
        .build(peer_name: "b", node_id: "peer-b", public_key: identity_b.public_key_pem)
        .fingerprint
    end

    it "Mesh.request_admission returns a decision" do
      decision = Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      expect(decision).to be_a(Igniter::Cluster::Governance::AdmissionDecision)
    end

    it "Mesh.pending_admissions lists pending requests" do
      Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      expect(Igniter::Cluster::Mesh.pending_admissions.size).to eq(1)
    end

    it "Mesh.approve_admission! admits the peer" do
      Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      request_id = Igniter::Cluster::Mesh.pending_admissions.first.request_id
      decision = Igniter::Cluster::Mesh.approve_admission!(request_id)
      expect(decision).to be_admitted
      expect(Igniter::Cluster::Mesh.pending_admissions).to be_empty
    end

    it "Mesh.reject_admission! rejects the peer" do
      Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      request_id = Igniter::Cluster::Mesh.pending_admissions.first.request_id
      decision = Igniter::Cluster::Mesh.reject_admission!(request_id, reason: "not authorised")
      expect(decision).to be_rejected
    end

    it "auto-admits when admission_policy has a matching known_key" do
      Igniter::Cluster::Mesh.configure do |c|
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(
          known_keys: { "peer-b" => fp_b }
        )
      end
      decision = Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      expect(decision).to be_admitted
      expect(Igniter::Cluster::Mesh.pending_admissions).to be_empty
    end

    it "records admission events in the governance trail" do
      Igniter::Cluster::Mesh.request_admission(
        peer_name: "node-b", node_id: "peer-b", public_key: identity_b.public_key_pem
      )
      trail_types = Igniter::Cluster::Mesh.config.governance_trail.events.map { |e| e[:type] }
      expect(trail_types).to include(:admission_requested, :admission_pending)
    end

    describe "PeerRegistry auto-registration (Phase 11)" do
      it "auto-registers peer in PeerRegistry when url provided and auto-admitted" do
        Igniter::Cluster::Mesh.configure do |c|
          c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(
            known_keys: { "peer-b" => fp_b }
          )
        end
        Igniter::Cluster::Mesh.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567",
          capabilities: [:database, :rag]
        )
        peer = Igniter::Cluster::Mesh.config.peer_registry.peer_named("node-b")
        expect(peer).not_to be_nil
        expect(peer.url).to eq("http://node-b:4567")
        expect(peer.capabilities).to include(:database, :rag)
      end

      it "peer becomes routable via Mesh.query after auto-registration" do
        Igniter::Cluster::Mesh.configure do |c|
          c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(
            known_keys: { "peer-b" => fp_b }
          )
        end
        Igniter::Cluster::Mesh.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567",
          capabilities: [:database]
        )
        result = Igniter::Cluster::Mesh.query.with(:database).map(&:name)
        expect(result).to include("node-b")
      end

      it "auto-registers peer after operator approval via Mesh.approve_admission!" do
        Igniter::Cluster::Mesh.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem,
          url: "http://node-b:4567",
          capabilities: [:rag]
        )
        expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("node-b")).to be_nil

        request_id = Igniter::Cluster::Mesh.pending_admissions.first.request_id
        Igniter::Cluster::Mesh.approve_admission!(request_id)

        peer = Igniter::Cluster::Mesh.config.peer_registry.peer_named("node-b")
        expect(peer).not_to be_nil
        expect(peer.url).to eq("http://node-b:4567")
      end

      it "does not register when no url provided (stays pending/approved without routing)" do
        Igniter::Cluster::Mesh.request_admission(
          peer_name: "node-b", node_id: "peer-b",
          public_key: identity_b.public_key_pem
        )
        request_id = Igniter::Cluster::Mesh.pending_admissions.first.request_id
        Igniter::Cluster::Mesh.approve_admission!(request_id)
        expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("node-b")).to be_nil
      end
    end
  end
end
