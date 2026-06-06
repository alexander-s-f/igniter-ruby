# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter Mesh — GET /v1/mesh/sd (Prometheus HTTP SD)" do
  after { Igniter::Cluster::Mesh.reset! }

  def make_peer(name, url, caps = [])
    Igniter::Cluster::Mesh::Peer.new(name: name, url: url, capabilities: Array(caps).map(&:to_sym))
  end

  def handler
    Igniter::Server::Handlers::MeshSdHandler.new(nil, nil)
  end

  def call_handler
    handler.call(params: {}, body: {})
  end

  def parsed_body(result)
    JSON.parse(result[:body])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Response shape
  # ─────────────────────────────────────────────────────────────────────────────
  describe "response shape" do
    before do
      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name          = "self"
        c.local_url          = "http://self:4567"
        c.discovery_interval = 60
      end
      Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("node-a", "http://node-a:4567", %i[orders inventory]))
    end

    it "returns HTTP 200" do
      expect(call_handler[:status]).to eq(200)
    end

    it "returns Content-Type application/json" do
      expect(call_handler[:headers]["Content-Type"]).to eq("application/json")
    end

    it "returns an array" do
      expect(parsed_body(call_handler)).to be_an(Array)
    end

    it "each entry has targets and labels keys" do
      entry = parsed_body(call_handler).first
      expect(entry).to include("targets", "labels")
    end

    it "targets is an array with one host:port string" do
      entry = parsed_body(call_handler).first
      expect(entry["targets"]).to eq(["node-a:4567"])
    end

    it "labels include __meta_igniter_peer_name" do
      entry = parsed_body(call_handler).first
      expect(entry["labels"]["__meta_igniter_peer_name"]).to eq("node-a")
    end

    it "labels include __meta_igniter_capabilities as comma-separated string" do
      entry = parsed_body(call_handler).first
      expect(entry["labels"]["__meta_igniter_capabilities"]).to eq("orders,inventory")
    end

    it "capabilities label is empty string when peer has no capabilities" do
      Igniter::Cluster::Mesh.reset!
      Igniter::Cluster::Mesh.configure { |c| c.discovery_interval = 60 }
      Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("bare", "http://bare:4567"))

      entry = parsed_body(call_handler).first
      expect(entry["labels"]["__meta_igniter_capabilities"]).to eq("")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # host:port extraction
  # ─────────────────────────────────────────────────────────────────────────────
  describe "host:port extraction" do
    before do
      Igniter::Cluster::Mesh.configure { |c| c.discovery_interval = 60 }
    end

    [
      ["http://node-a:4567",          "node-a:4567"],
      ["http://node-a.internal:4567", "node-a.internal:4567"],
      ["http://192.168.1.10:8080",    "192.168.1.10:8080"],
      ["http://localhost:4567",       "localhost:4567"]
    ].each do |url, expected|
      it "extracts #{expected} from #{url}" do
        Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("p", url))
        entry = parsed_body(call_handler).first
        expect(entry["targets"]).to eq([expected])
      end
    end

    it "falls back to the raw URL if URI parsing fails" do
      bad_url = "not a url !!!"
      Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("broken", bad_url))
      entry = parsed_body(call_handler).first
      # Should not raise; targets contains something (the raw url)
      expect(entry["targets"]).not_to be_empty
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Static + dynamic merge (same logic as MeshPeersListHandler)
  # ─────────────────────────────────────────────────────────────────────────────
  describe "static + dynamic peer merge" do
    it "includes both static and dynamic peers" do
      Igniter::Cluster::Mesh.configure do |c|
        c.discovery_interval = 60
        c.add_peer "static-peer", url: "http://static:4567", capabilities: [:billing]
      end
      Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("dynamic-peer", "http://dynamic:4567", [:orders]))

      names = parsed_body(call_handler).map { |e| e["labels"]["__meta_igniter_peer_name"] }
      expect(names).to include("static-peer", "dynamic-peer")
    end

    it "static peer takes precedence when name collides with dynamic" do
      Igniter::Cluster::Mesh.configure do |c|
        c.discovery_interval = 60
        c.add_peer "shared", url: "http://static-shared:4567", capabilities: [:billing]
      end
      Igniter::Cluster::Mesh.config.peer_registry.register(make_peer("shared", "http://dynamic-shared:4567", [:orders]))

      entries = parsed_body(call_handler)
      shared  = entries.find { |e| e["labels"]["__meta_igniter_peer_name"] == "shared" }
      expect(shared["targets"]).to eq(["static-shared:4567"])
      expect(entries.count { |e| e["labels"]["__meta_igniter_peer_name"] == "shared" }).to eq(1)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Empty cases
  # ─────────────────────────────────────────────────────────────────────────────
  describe "empty cases" do
    it "returns [] when no peers are registered" do
      Igniter::Cluster::Mesh.configure { |c| c.discovery_interval = 60 }
      expect(parsed_body(call_handler)).to eq([])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Router integration
  # ─────────────────────────────────────────────────────────────────────────────
  describe "router integration — GET /v1/mesh/sd" do
    let(:config) { Igniter::Server::Config.new }
    let(:router) { Igniter::Server::Router.new(config) }

    before do
      Igniter::Cluster::Mesh.configure do |c|
        c.discovery_interval = 60
        c.add_peer "api", url: "http://api:4567", capabilities: [:api]
      end
    end

    it "dispatches to MeshSdHandler and returns 200" do
      result = router.call("GET", "/v1/mesh/sd", "")
      expect(result[:status]).to eq(200)
    end

    it "response body is valid JSON array" do
      result = router.call("GET", "/v1/mesh/sd", "")
      body = JSON.parse(result[:body])
      expect(body).to be_an(Array)
    end

    it "response contains the registered peer" do
      result = router.call("GET", "/v1/mesh/sd", "")
      body = JSON.parse(result[:body])
      names = body.map { |e| e["labels"]["__meta_igniter_peer_name"] }
      expect(names).to include("api")
    end

    it "is distinct from GET /v1/mesh/peers" do
      sd_result   = router.call("GET", "/v1/mesh/sd", "")
      peer_result = router.call("GET", "/v1/mesh/peers", "")

      sd_body   = JSON.parse(sd_result[:body])
      peer_body = JSON.parse(peer_result[:body])

      # SD has targets/labels, peers has name/url/capabilities
      expect(sd_body.first).to include("targets", "labels")
      expect(peer_body.first).to include("name", "url", "capabilities")
    end
  end
end
