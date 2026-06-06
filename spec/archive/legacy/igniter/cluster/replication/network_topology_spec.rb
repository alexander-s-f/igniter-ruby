# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::NetworkTopology do
  subject(:topology) { described_class.new }

  describe "#register" do
    it "returns a NodeEntry" do
      entry = topology.register(node_id: "n1", host: "10.0.0.1")
      expect(entry).to be_a(Igniter::Cluster::Replication::NetworkTopology::NodeEntry)
    end

    it "stores the node as healthy by default" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      expect(topology.nodes.first.healthy).to be true
    end

    it "stores capabilities in the profile" do
      topology.register(node_id: "n1", host: "10.0.0.1", capabilities: [:local_llm])
      expect(topology.nodes.first.capabilities).to eq([:local_llm])
    end

    it "overwrites an existing entry with the same node_id" do
      topology.register(node_id: "n1", host: "10.0.0.1", capabilities: [:ruby])
      topology.register(node_id: "n1", host: "10.0.0.2", capabilities: [:local_llm])
      expect(topology.size).to eq(1)
      expect(topology.nodes.first.capabilities).to eq([:local_llm])
    end
  end

  describe "#touch" do
    it "returns true when the node exists" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      expect(topology.touch(node_id: "n1")).to be true
    end

    it "returns false for an unknown node" do
      expect(topology.touch(node_id: "ghost")).to be false
    end

    it "updates last_seen_at" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      before = topology.nodes.first.last_seen_at
      sleep 0.01
      topology.touch(node_id: "n1")
      after = topology.nodes.first.last_seen_at
      expect(after).to be >= before
    end
  end

  describe "#mark_unhealthy" do
    it "sets healthy to false" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      topology.mark_unhealthy(node_id: "n1")
      expect(topology.nodes.first.healthy).to be false
    end

    it "returns false for an unknown node" do
      expect(topology.mark_unhealthy(node_id: "ghost")).to be false
    end
  end

  describe "#remove" do
    it "removes the node and returns the entry" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      removed = topology.remove(node_id: "n1")
      expect(removed).to be_a(Igniter::Cluster::Replication::NetworkTopology::NodeEntry)
      expect(topology.size).to eq(0)
    end

    it "returns nil when the node is not found" do
      expect(topology.remove(node_id: "ghost")).to be_nil
    end
  end

  describe "#nodes" do
    before do
      topology.register(node_id: "llm-1", host: "10.0.0.1", capabilities: %i[local_llm container_runtime], tags: [:linux])
      topology.register(node_id: "db-1", host: "10.0.0.2", capabilities: [:data_store], tags: [:linux])
    end

    it "returns all nodes when no filter is given" do
      expect(topology.nodes.size).to eq(2)
    end

    it "filters by capability" do
      nodes = topology.nodes(capability: :local_llm)
      expect(nodes.map(&:node_id)).to contain_exactly("llm-1")
    end

    it "filters by capability query" do
      nodes = topology.nodes(query: { all_of: %i[local_llm container_runtime], tags: [:linux] })
      expect(nodes.map(&:node_id)).to contain_exactly("llm-1")
    end
  end

  describe "#needs_capability?" do
    it "returns true when no node with the capability exists" do
      expect(topology.needs_capability?(:local_llm)).to be true
    end

    it "returns false when a healthy node with the capability exists" do
      topology.register(node_id: "w1", host: "10.0.0.1", capabilities: [:local_llm])
      expect(topology.needs_capability?(:local_llm)).to be false
    end

    it "returns true when only unhealthy nodes have the capability" do
      topology.register(node_id: "w1", host: "10.0.0.1", capabilities: [:local_llm])
      topology.mark_unhealthy(node_id: "w1")
      expect(topology.needs_capability?(:local_llm)).to be true
    end
  end

  describe "#needs_capability_query?" do
    it "returns true when no healthy node matches the query" do
      expect(topology.needs_capability_query?(%i[local_llm container_runtime])).to be true
    end

    it "returns false when a healthy node matches the query" do
      topology.register(node_id: "n1", host: "10.0.0.1", capabilities: %i[local_llm container_runtime], tags: [:linux])
      expect(topology.needs_capability_query?(all_of: %i[local_llm container_runtime], tags: [:linux])).to be false
    end
  end

  describe "#healthy_count" do
    it "counts only healthy nodes" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      topology.register(node_id: "n2", host: "10.0.0.2")
      topology.mark_unhealthy(node_id: "n1")
      expect(topology.healthy_count).to eq(1)
    end
  end

  describe "#size" do
    it "counts all nodes regardless of health" do
      topology.register(node_id: "n1", host: "10.0.0.1")
      topology.mark_unhealthy(node_id: "n1")
      topology.register(node_id: "n2", host: "10.0.0.2")
      expect(topology.size).to eq(2)
    end
  end

  describe "#node_ids" do
    it "returns all registered IDs" do
      topology.register(node_id: "a", host: "10.0.0.1")
      topology.register(node_id: "b", host: "10.0.0.2")
      expect(topology.node_ids).to contain_exactly("a", "b")
    end
  end
end
