# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe "OP4 — Sync Hub Profile" do
  subject(:proto) { Igniter::Store::Protocol.new }

  def write_tasks
    proto.write(store: :tasks, key: "t1", value: { title: "Alpha", status: :open })
    proto.write(store: :tasks, key: "t2", value: { title: "Beta",  status: :done })
    proto.write(store: :tasks, key: "t3", value: { title: "Gamma", status: :open })
  end

  # ------------------------------------------------------------------ SyncProfile value object

  describe "SyncProfile value object" do
    it "full? is true when cursor is nil" do
      profile = Igniter::Store::Protocol::SyncProfile.new(
        schema_version: 1, kind: :sync_hub_profile,
        generated_at: 0.0, cursor: nil,
        descriptors: {}, facts: [], retention: {},
        compaction_receipts: [], subscription_checkpoints: {}
      )
      expect(profile.full?).to        be true
      expect(profile.incremental?).to be false
    end

    it "incremental? is true when cursor is present" do
      profile = Igniter::Store::Protocol::SyncProfile.new(
        schema_version: 1, kind: :sync_hub_profile,
        generated_at: 0.0, cursor: { kind: :timestamp, value: 1.0 },
        descriptors: {}, facts: [], retention: {},
        compaction_receipts: [], subscription_checkpoints: {}
      )
      expect(profile.incremental?).to be true
    end

    it "fact_count returns facts.size" do
      profile = Igniter::Store::Protocol::SyncProfile.new(
        schema_version: 1, kind: :sync_hub_profile,
        generated_at: 0.0, cursor: nil,
        descriptors: {}, facts: [{ id: "f1" }, { id: "f2" }], retention: {},
        compaction_receipts: [], subscription_checkpoints: {}
      )
      expect(profile.fact_count).to eq(2)
    end

    it "next_cursor returns nil when facts is empty" do
      profile = Igniter::Store::Protocol::SyncProfile.new(
        schema_version: 1, kind: :sync_hub_profile,
        generated_at: 0.0, cursor: nil,
        descriptors: {}, facts: [], retention: {},
        compaction_receipts: [], subscription_checkpoints: {}
      )
      expect(profile.next_cursor).to be_nil
    end

    it "next_cursor returns a timestamp cursor pointing to the latest fact" do
      facts = [
        { transaction_time: 1000.0 },
        { transaction_time: 3000.0 },
        { transaction_time: 2000.0 }
      ]
      profile = Igniter::Store::Protocol::SyncProfile.new(
        schema_version: 1, kind: :sync_hub_profile,
        generated_at: 0.0, cursor: nil,
        descriptors: {}, facts: facts, retention: {},
        compaction_receipts: [], subscription_checkpoints: {}
      )
      expect(profile.next_cursor).to eq({ kind: :timestamp, value: 3000.0 })
    end
  end

  # ------------------------------------------------------------------ IgniterStore#fact_log_all

  describe "IgniterStore#fact_log_all" do
    let(:inner) { Igniter::Store::IgniterStore.new }

    it "returns all facts when no range given" do
      inner.write(store: :tasks, key: "t1", value: { n: 1 })
      inner.write(store: :tasks, key: "t2", value: { n: 2 })
      expect(inner.fact_log_all.size).to eq(2)
    end

    it "filters by since:" do
      inner.write(store: :tasks, key: "t1", value: { n: 1 })
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      inner.write(store: :tasks, key: "t2", value: { n: 2 })
      result = inner.fact_log_all(since: checkpoint)
      expect(result.size).to eq(1)
      expect(result.first.key).to eq("t2")
    end

    it "filters by as_of:" do
      inner.write(store: :tasks, key: "t1", value: { n: 1 })
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      inner.write(store: :tasks, key: "t2", value: { n: 2 })
      result = inner.fact_log_all(as_of: checkpoint)
      expect(result.size).to eq(1)
      expect(result.first.key).to eq("t1")
    end
  end

  # ------------------------------------------------------------------ Interpreter#replay

  describe "Interpreter#replay" do
    before { write_tasks }

    it "returns all fact packets when no filter" do
      packets = proto.replay
      expect(packets.size).to eq(3)
      expect(packets.first).to include(kind: :fact, schema_version: 1)
    end

    it "each packet carries id, store, key, value, value_hash, causation, transaction_time" do
      packet = proto.replay.first
      expect(packet).to have_key(:id)
      expect(packet).to have_key(:store)
      expect(packet).to have_key(:key)
      expect(packet).to have_key(:value)
      expect(packet).to have_key(:value_hash)
      expect(packet).to have_key(:causation)
      expect(packet).to have_key(:transaction_time)
    end

    it "filters by store when filter: { store: } given" do
      proto.write(store: :projects, key: "p1", value: { name: "Acme" })
      task_packets = proto.replay(filter: { store: :tasks })
      expect(task_packets.all? { |p| p[:store] == :tasks }).to be true
      expect(task_packets.size).to eq(3)
    end

    it "filters a history by store and key" do
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 7.0 })
      target = proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 8.5 })
      proto.append(history: :tracker_logs, event: { tracker_id: "training", value: 45.0 })

      packets = proto.replay(filter: { store: :tracker_logs, key: target.key })

      expect(packets.map { |packet| packet[:key] }).to eq([target.key])
      expect(packets.first[:value]).to include(tracker_id: "sleep", value: 8.5)
    end

    it "filters a history by partition key and partition value" do
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 7.0 }, partition_key: :tracker_id)
      proto.append(history: :tracker_logs, event: { tracker_id: "training", value: 45.0 }, partition_key: :tracker_id)
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 8.5 }, partition_key: :tracker_id)

      packets = proto.replay(filter: {
        store: :tracker_logs, partition_key: :tracker_id, partition_value: "sleep"
      })

      expect(packets.map { |packet| packet[:value][:value] }).to eq([7.0, 8.5])
    end

    it "combines partition replay with from: and to:" do
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 6.0 }, partition_key: :tracker_id)
      sleep 0.005
      lower = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 7.0 }, partition_key: :tracker_id)
      sleep 0.005
      upper = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 8.5 }, partition_key: :tracker_id)

      packets = proto.replay(
        from: lower,
        to: upper,
        filter: { store: :tracker_logs, partition_key: :tracker_id, partition_value: "sleep" }
      )

      expect(packets.map { |packet| packet[:value][:value] }).to eq([7.0])
    end

    it "filters by time range with from: and to:" do
      sleep 0.005
      mid = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      proto.write(store: :tasks, key: "t4", value: { title: "Late" })

      late = proto.replay(from: mid)
      expect(late.size).to eq(1)
      expect(late.first[:key]).to eq("t4")
    end
  end

  # ------------------------------------------------------------------ Interpreter#sync_hub_profile

  describe "Interpreter#sync_hub_profile" do
    before { write_tasks }

    it "returns a SyncProfile" do
      profile = proto.sync_hub_profile
      expect(profile).to be_a(Igniter::Store::Protocol::SyncProfile)
    end

    it "full sync: cursor is nil, all facts are included" do
      profile = proto.sync_hub_profile
      expect(profile.full?).to be true
      expect(profile.fact_count).to eq(3)
    end

    it "profile has schema_version: 1, kind: :sync_hub_profile, generated_at" do
      profile = proto.sync_hub_profile
      expect(profile.schema_version).to eq(1)
      expect(profile.kind).to           eq(:sync_hub_profile)
      expect(profile.generated_at).to   be_a(Float)
    end

    it "includes the OP2 metadata_snapshot as descriptors" do
      proto.register_store(schema_version: 1, kind: :store, name: :tasks, key: :id, fields: [])
      profile = proto.sync_hub_profile
      expect(profile.descriptors).to have_key(:schema_version)
      expect(profile.descriptors[:schema_version]).to eq(1)
    end

    it "includes retention snapshot" do
      expect(proto.sync_hub_profile.retention).to be_a(Hash)
    end

    it "includes (possibly empty) compaction_receipts" do
      expect(proto.sync_hub_profile.compaction_receipts).to be_an(Array)
    end

    it "includes subscription_checkpoints placeholder" do
      expect(proto.sync_hub_profile.subscription_checkpoints).to be_a(Hash)
    end

    it "next_cursor points to the latest fact's timestamp" do
      profile = proto.sync_hub_profile
      cursor  = profile.next_cursor
      expect(cursor[:kind]).to  eq(:timestamp)
      expect(cursor[:value]).to be_a(Float)
    end

    context "incremental sync (cursor: given)" do
      it "returns only facts written after the cursor timestamp" do
        proto.write(store: :tasks, key: "t1", value: { title: "Old" })
        sleep 0.005
        cursor = { kind: :timestamp, value: Process.clock_gettime(Process::CLOCK_REALTIME) }
        sleep 0.005
        proto.write(store: :tasks, key: "t4", value: { title: "New" })

        profile = proto.sync_hub_profile(cursor: cursor)
        expect(profile.incremental?).to be true
        # Only the new fact (t4) written after cursor should be present.
        # The 3 facts from before + the "Old" t1 rewrite are before the cursor.
        expect(profile.facts.any? { |f| f[:key] == "t4" }).to be true
        expect(profile.facts.none? { |f| f[:key] == "t4" && f[:value][:title] == "Old" }).to be true
      end

      it "incremental profile has fewer facts than a full sync" do
        cursor = { kind: :timestamp, value: Process.clock_gettime(Process::CLOCK_REALTIME) }
        sleep 0.005
        proto.write(store: :tasks, key: "t5", value: { title: "After" })

        full        = proto.sync_hub_profile
        incremental = proto.sync_hub_profile(cursor: cursor)

        expect(incremental.fact_count).to be < full.fact_count
        expect(incremental.fact_count).to eq(1)
      end
    end

    context "store filter" do
      it "restricts facts to specified stores only" do
        proto.write(store: :projects, key: "p1", value: { name: "Proj" })

        profile = proto.sync_hub_profile(stores: [:tasks])
        expect(profile.facts.all? { |f| f[:store] == :tasks }).to be true
        expect(profile.fact_count).to eq(3)
      end
    end
  end

  # ------------------------------------------------------------------ WireEnvelope: op :sync_hub_profile

  describe "WireEnvelope op: :sync_hub_profile" do
    let(:wire) { proto.wire }

    before { write_tasks }

    def env(op, packet = {})
      { protocol: :igniter_store, schema_version: 1,
        request_id: "req_op4", op: op, packet: packet }
    end

    it "returns a SyncProfile as result" do
      resp = wire.dispatch(env(:sync_hub_profile))
      expect(resp[:status]).to         eq(:ok)
      expect(resp[:result]).to         be_a(Igniter::Store::Protocol::SyncProfile)
      expect(resp[:result].fact_count).to eq(3)
    end

    it "passes cursor: through for incremental sync" do
      cursor = { kind: :timestamp, value: Process.clock_gettime(Process::CLOCK_REALTIME) }
      sleep 0.005
      proto.write(store: :tasks, key: "t4", value: { title: "New" })

      resp = wire.dispatch(env(:sync_hub_profile, { cursor: cursor }))
      expect(resp[:result].incremental?).to  be true
      expect(resp[:result].fact_count).to    eq(1)
    end
  end

  # ------------------------------------------------------------------ WireEnvelope: op :replay

  describe "WireEnvelope op: :replay" do
    let(:wire) { proto.wire }

    before { write_tasks }

    def env(op, packet = {})
      { protocol: :igniter_store, schema_version: 1,
        request_id: "req_replay", op: op, packet: packet }
    end

    it "returns facts and count" do
      resp = wire.dispatch(env(:replay))
      expect(resp[:status]).to           eq(:ok)
      expect(resp[:result][:count]).to   eq(3)
      expect(resp[:result][:facts]).to   all(include(kind: :fact))
    end

    it "filters by store via filter:" do
      proto.write(store: :projects, key: "p1", value: { name: "X" })
      resp = wire.dispatch(env(:replay, { filter: { store: :tasks } }))
      expect(resp[:result][:count]).to eq(3)
    end

    it "filters by partition through the wire envelope" do
      proto.append(history: :tracker_logs, event: { tracker_id: "sleep", value: 7.0 }, partition_key: :tracker_id)
      proto.append(history: :tracker_logs, event: { tracker_id: "training", value: 45.0 }, partition_key: :tracker_id)

      resp = wire.dispatch(env(:replay, {
        filter: { store: :tracker_logs, partition_key: :tracker_id, partition_value: "sleep" }
      }))

      expect(resp[:status]).to eq(:ok)
      expect(resp[:result][:count]).to eq(1)
      expect(resp[:result][:facts].first[:value]).to include(value: 7.0)
    end
  end
end
