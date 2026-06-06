# frozen_string_literal: true

require "igniter/cluster"

RSpec.describe Igniter::Cluster::Consensus do
  # ── StateMachine ──────────────────────────────────────────────────────────────

  describe Igniter::Cluster::Consensus::StateMachine do
    describe ".call" do
      it "sets a key via default KV protocol" do
        result = described_class.call({}, { key: :price, value: 99 })
        expect(result).to eq({ price: 99 })
      end

      it "overwrites an existing key" do
        result = described_class.call({ price: 50 }, { key: :price, value: 99 })
        expect(result).to eq({ price: 99 })
      end

      it "deletes a key when op: :delete" do
        result = described_class.call({ price: 99, qty: 5 }, { key: :price, op: :delete })
        expect(result).to eq({ qty: 5 })
      end

      it "returns state unchanged for nil command" do
        state = { price: 99 }
        expect(described_class.call(state, nil)).to eq(state)
      end

      it "returns state unchanged for command without :key" do
        state = { price: 99 }
        expect(described_class.call(state, { type: :unknown_op })).to eq(state)
      end

      it "does not mutate the original state" do
        state  = { price: 99 }.freeze
        result = described_class.call(state, { key: :qty, value: 10 })
        expect(result).to eq({ price: 99, qty: 10 })
        expect(state).to eq({ price: 99 })
      end
    end

    describe "subclass with custom reducers" do
      let(:machine) do
        Class.new(Igniter::Cluster::Consensus::StateMachine) do
          apply :set    do |state, cmd| state.merge(cmd[:key] => cmd[:value]) end
          apply :delete do |state, cmd| state.reject { |k, _| k == cmd[:key] } end
          apply :incr   do |state, cmd|
            state.merge(cmd[:key] => (state[cmd[:key]] || 0) + cmd[:by])
          end
        end
      end

      it "dispatches :set to registered handler" do
        expect(machine.call({}, { type: :set, key: :x, value: 10 })).to eq({ x: 10 })
      end

      it "dispatches :delete" do
        expect(machine.call({ x: 1, y: 2 }, { type: :delete, key: :x })).to eq({ y: 2 })
      end

      it "dispatches :incr" do
        result = machine.call({ count: 5 }, { type: :incr, key: :count, by: 3 })
        expect(result).to eq({ count: 8 })
      end

      it "falls back to default KV for unregistered type" do
        expect(machine.call({}, { key: :a, value: 1 })).to eq({ a: 1 })
      end

      it "does not mutate original state" do
        state  = { x: 1 }.freeze
        result = machine.call(state, { type: :set, key: :y, value: 2 })
        expect(result).to eq({ x: 1, y: 2 })
        expect(state).to eq({ x: 1 })
      end
    end
  end

  # ── Node (unit) ──────────────────────────────────────────────────────────────

  describe Igniter::Cluster::Consensus::Node do
    describe ".quorum" do
      it "returns correct majority for 3-node cluster" do
        expect(described_class.quorum(3)).to eq(2)
      end

      it "returns correct majority for 5-node cluster" do
        expect(described_class.quorum(5)).to eq(3)
      end

      it "returns correct majority for 7-node cluster" do
        expect(described_class.quorum(7)).to eq(4)
      end
    end
  end

  # ── Cluster (unit) ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::Consensus::Cluster do
    let(:node_ids) { %i[c1 c2 c3] }
    subject(:cluster) { described_class.new(nodes: node_ids) }

    describe "#quorum_size" do
      it "returns majority of a 3-node cluster" do
        expect(cluster.quorum_size).to eq(2)
      end

      it "returns majority of a 5-node cluster" do
        c5 = described_class.new(nodes: %i[a b c d e])
        expect(c5.quorum_size).to eq(3)
      end
    end

    describe "#has_quorum?" do
      it "returns false when no nodes are alive" do
        expect(cluster.has_quorum?).to be false
      end
    end

    describe "#alive_count" do
      it "returns 0 when no nodes are alive" do
        expect(cluster.alive_count).to eq(0)
      end
    end

    describe "#leader" do
      it "returns nil when no nodes are alive" do
        expect(cluster.leader).to be_nil
      end
    end

    describe "#read_contract" do
      it "returns a ReadQuery" do
        q = cluster.read_contract(key: :price)
        expect(q).to be_a(Igniter::Cluster::Consensus::ReadQuery)
      end
    end

    describe "#write when no leader" do
      it "raises NoLeaderError" do
        expect { cluster.write(key: :x, value: 1) }
          .to raise_error(Igniter::Cluster::Consensus::NoLeaderError)
      end
    end

    describe "#read when no leader" do
      it "raises NoLeaderError" do
        expect { cluster.read(:x) }
          .to raise_error(Igniter::Cluster::Consensus::NoLeaderError)
      end
    end

    describe "#wait_for_leader when no leader" do
      it "raises NoLeaderError after timeout" do
        expect { cluster.wait_for_leader(timeout: 0.1) }
          .to raise_error(Igniter::Cluster::Consensus::NoLeaderError, /No leader elected/)
      end
    end
  end

  # ── Integration (full cluster) ───────────────────────────────────────────────

  describe "full cluster integration" do
    let(:node_ids) { %i[it1 it2 it3 it4 it5] }
    let(:cluster)  { Igniter::Cluster::Consensus::Cluster.start(nodes: node_ids) }

    after do
      cluster.stop! rescue nil
      node_ids.each { |n| Igniter::Registry.unregister(n) rescue nil }
    end

    it "elects a leader" do
      leader = cluster.wait_for_leader
      expect(leader).not_to be_nil
      expect(leader.state[:role]).to eq(:leader)
    end

    it "reports has_quorum? once nodes are alive" do
      cluster.wait_for_leader
      expect(cluster.has_quorum?).to be true
    end

    it "replicates a write to all nodes" do
      cluster.wait_for_leader
      cluster.write(key: :price, value: 99)
      sleep 0.5

      alive = node_ids.filter_map { |n| Igniter::Registry.find(n) }.select(&:alive?)
      alive.each do |ref|
        expect(ref.state[:state_machine][:price]).to eq(99)
      end
    end

    it "reads a committed value" do
      cluster.wait_for_leader
      cluster.write(key: :qty, value: 7)
      sleep 0.4
      expect(cluster.read(:qty)).to eq(7)
    end

    it "returns state_machine_snapshot" do
      cluster.wait_for_leader
      cluster.write(key: :a, value: 1)
      cluster.write(key: :b, value: 2)
      sleep 0.4
      snap = cluster.state_machine_snapshot
      expect(snap).to include(a: 1, b: 2)
    end

    it "provides a ReadQuery contract" do
      cluster.wait_for_leader
      cluster.write(key: :status, value: :active)
      sleep 0.4

      q = cluster.read_contract(key: :status)
      q.resolve_all
      expect(q.result.value).to eq(:active)
    end

    it "raises NoLeaderError when quorum is lost" do
      cluster.wait_for_leader

      # Kill enough nodes to break quorum (keep only 1)
      node_ids.first(4).each do |nid|
        Igniter::Registry.find(nid)&.kill
        Igniter::Registry.unregister(nid)
      end
      expect(cluster.has_quorum?).to be false

      expect { cluster.write(key: :x, value: 1) }
        .to raise_error(Igniter::Cluster::Consensus::NoLeaderError)
    end

    it "raises ResolutionError from ReadQuery when cluster has no leader" do
      surviving = node_ids.first(2)
      # Kill the rest immediately (before any election completes)
      (node_ids - surviving).each do |nid|
        Igniter::Registry.find(nid)&.kill
        Igniter::Registry.unregister(nid)
      end
      sleep 0.2

      partial = Igniter::Cluster::Consensus::Cluster.new(nodes: surviving)
      q = partial.read_contract(key: :price)
      expect { q.resolve_all }.to raise_error(Igniter::Error)
    end

    it "survives leader crash and elects a new leader" do
      leader_ref = cluster.wait_for_leader
      old_id     = leader_ref.state[:node_id]

      Igniter::Registry.find(old_id)&.kill
      Igniter::Registry.unregister(old_id)

      remaining = Igniter::Cluster::Consensus::Cluster.new(
        nodes: node_ids.reject { |n| n == old_id }
      )
      new_leader = remaining.wait_for_leader
      expect(new_leader.state[:node_id]).not_to eq(old_id)
    end

    context "with a custom state machine" do
      let(:counter_machine) do
        Class.new(Igniter::Cluster::Consensus::StateMachine) do
          apply :increment do |state, cmd|
            state.merge(cmd[:counter] => (state[cmd[:counter]] || 0) + cmd[:by])
          end
          apply :reset do |state, cmd|
            state.merge(cmd[:counter] => 0)
          end
        end
      end
      let(:cluster) do
        Igniter::Cluster::Consensus::Cluster.start(nodes: node_ids, state_machine: counter_machine)
      end

      it "applies custom commands" do
        cluster.wait_for_leader
        cluster.write(type: :increment, counter: :visits, by: 3)
        cluster.write(type: :increment, counter: :visits, by: 2)
        sleep 0.5
        expect(cluster.read(:visits)).to eq(5)
      end

      it "resets a counter" do
        cluster.wait_for_leader
        cluster.write(type: :increment, counter: :x, by: 10)
        sleep 0.3
        cluster.write(type: :reset, counter: :x)
        sleep 0.3
        expect(cluster.read(:x)).to eq(0)
      end

      it "replicates custom commands to all nodes" do
        cluster.wait_for_leader
        cluster.write(type: :increment, counter: :hits, by: 7)
        sleep 0.5

        alive = node_ids.filter_map { |n| Igniter::Registry.find(n) }.select(&:alive?)
        alive.each do |ref|
          expect(ref.state[:state_machine][:hits]).to eq(7)
        end
      end
    end
  end
end
