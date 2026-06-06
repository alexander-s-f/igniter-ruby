# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::LedgerClient::Client do
  class FakeTransport
    attr_reader :requests

    def initialize(response: nil)
      @response = response
      @requests = []
    end

    def dispatch(envelope)
      @requests << envelope
      result = case envelope[:op]
               when :register_descriptor
                 { kind: :store, status: :accepted, name: envelope[:packet][:name], warnings: [], errors: [] }
               when :write
                 { kind: :receipt, status: :accepted, store: envelope[:packet][:store], key: envelope[:packet][:key], fact_id: "fact_w", value_hash: "hash_w" }
               when :append
                 { kind: :append_receipt, status: :accepted, store: envelope[:packet][:history], key: "generated-key", fact_id: "fact_a", value_hash: "hash_a" }
               when :read
                 { value: { status: :open }, found: true }
               when :query
                 { items: [{ key: "o1", value: { status: :open } }], results: [{ status: :open }], count: 1 }
               when :resolve
                 { items: [{ key: "t1", value: { title: "Alpha" } }], results: [{ title: "Alpha" }], count: 1 }
               when :replay
                 { facts: [{ key: "evt_1" }], count: 1 }
               when :causation_chain
                 { chain: [{ id: "fact_1", value_hash: "hash_1", causation: nil }], count: 1 }
               when :lineage
                 {
                   subject: { store: "orders", key: "o1" },
                   chain: [{ id: "fact_1" }],
                   depth: 1,
                   derived_by: [],
                   proof_hash: "abc123"
                 }
               when :fact_ref
                 { found: true, ref: { id: "fact_1", store: "orders", key: "o1", value_hash: "hash_1" } }
               else
                 { op: envelope[:op], packet: envelope[:packet] }
               end

      @response || {
        protocol: :igniter_store,
        schema_version: 1,
        request_id: envelope[:request_id],
        status: :ok,
        result: result
      }
    end
  end

  class FakeSubscriptionTransport < FakeTransport
    attr_reader :subscribe_args

    def subscribe(stores:, cursor:, &block)
      @subscribe_args = { stores: stores, cursor: cursor }
      block.call("cursor" => { "sequence" => 3 }, "store" => "orders", "key" => "o1")
      Igniter::LedgerClient::Subscription.new
    end
  end

  it "dispatches write through a protocol envelope and returns result" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    result = client.write(store: :orders, key: "o1", value: { status: :open })

    expect(result).to be_a(Igniter::LedgerClient::Results::WriteResult)
    expect(result).to be_accepted
    expect(result.store).to eq(:orders)
    expect(result.key).to eq("o1")
    expect(transport.requests.first).to include(protocol: :igniter_store, schema_version: 1, op: :write)
  end

  it "raises LedgerClient::Error for error envelopes" do
    transport = FakeTransport.new(
      response: {
        protocol: :igniter_store,
        schema_version: 1,
        request_id: "req_test",
        status: :error,
        error: "boom"
      }
    )
    client = described_class.new(transport: transport)

    expect { client.metadata_snapshot }.to raise_error(Igniter::LedgerClient::Error, "boom")
  end

  it "wraps metadata and compaction reads" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    client.metadata_snapshot
    client.compaction_activity(store: :orders, kind: :exact_prune, limit: 10)

    expect(transport.requests.map { |r| r[:op] }).to eq(%i[metadata_snapshot compaction_activity])
    expect(transport.requests.last[:packet]).to include(store: :orders, kind: :exact_prune, limit: 10)
  end

  it "dispatches append through a first-class protocol operation" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    result = client.append(
      history: :contractable_events,
      event: { event_id: "evt_1", observation_id: "obs_1" },
      key: "client-key-1",
      partition_key: :observation_id,
      producer: { system: :spec }
    )

    packet = transport.requests.first[:packet]
    expect(result).to be_a(Igniter::LedgerClient::Results::AppendResult)
    expect(result).to be_accepted
    expect(result.store).to eq(:contractable_events)
    expect(result.key).to eq("generated-key")
    expect(transport.requests.first[:op]).to eq(:append)
    expect(packet).to include(history: :contractable_events, key: "client-key-1")
    expect(packet[:event]).to include(event_id: "evt_1")
    expect(packet[:partition_key]).to eq(:observation_id)
    expect(packet[:producer]).to eq(system: :spec)
  end

  it "normalizes descriptor, read, query, resolve, and replay results" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    descriptor = client.register_descriptor(kind: :store, name: :orders)
    read = client.read(store: :orders, key: "o1")
    query = client.query(store: :orders, where: { status: :open })
    resolve = client.resolve(relation: :project_tasks, from: "p1")
    replay = client.replay(store: :order_events)

    expect(descriptor).to be_a(Igniter::LedgerClient::Results::ReceiptResult)
    expect(descriptor).to be_accepted
    expect(read).to be_a(Igniter::LedgerClient::Results::ReadResult)
    expect(read).to be_found
    expect(read.value).to eq(status: :open)
    expect(query.items).to eq([{ key: "o1", value: { status: :open } }])
    expect(query.results).to eq([{ status: :open }])
    expect(query.count).to eq(1)
    expect(resolve).to be_a(Igniter::LedgerClient::Results::ResolveResult)
    expect(resolve.items).to eq([{ key: "t1", value: { title: "Alpha" } }])
    expect(resolve.results).to eq([{ title: "Alpha" }])
    expect(resolve.count).to eq(1)
    expect(replay.facts).to eq([{ key: "evt_1" }])
    expect(replay.count).to eq(1)
  end

  it "normalizes provenance result models" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    chain = client.causation_chain(store: :orders, key: "o1")
    lineage = client.lineage(store: :orders, key: "o1")
    ref = client.fact_ref("fact_1")

    expect(chain).to be_a(Igniter::LedgerClient::Results::CausationChainResult)
    expect(chain.count).to eq(1)
    expect(chain.chain.first[:id]).to eq("fact_1")
    expect(lineage).to be_a(Igniter::LedgerClient::Results::LineageResult)
    expect(lineage.subject).to eq(store: "orders", key: "o1")
    expect(lineage.depth).to eq(1)
    expect(ref).to be_a(Igniter::LedgerClient::Results::FactRefResult)
    expect(ref).to be_found
    expect(ref.ref).to include(id: "fact_1", store: "orders")
    expect(transport.requests.last[:op]).to eq(:fact_ref)
  end

  it "builds replay filters from store and key convenience arguments" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    client.replay(store: :order_events, key: "evt_1")

    expect(transport.requests.first[:packet][:filter]).to eq(store: :order_events, key: "evt_1")
  end

  it "builds replay filters from partition convenience arguments" do
    transport = FakeTransport.new
    client = described_class.new(transport: transport)

    client.replay(
      store: :tracker_logs,
      partition_key: :tracker_id,
      partition_value: "sleep",
      from: 1.0,
      to: 2.0
    )

    packet = transport.requests.first[:packet]
    expect(packet[:from]).to eq(1.0)
    expect(packet[:to]).to eq(2.0)
    expect(packet[:filter]).to eq(
      store: :tracker_logs,
      partition_key: :tracker_id,
      partition_value: "sleep"
    )
  end

  it "rejects ambiguous replay filter arguments" do
    client = described_class.new(transport: FakeTransport.new)

    expect { client.replay(store: :events, filter: { store: :other_events }) }
      .to raise_error(ArgumentError, /cannot be combined/)
  end

  it "subscribes through the transport and yields normalized change events" do
    transport = FakeSubscriptionTransport.new
    client = described_class.new(transport: transport)
    received = []

    subscription = client.subscribe(stores: [:orders], cursor: { sequence: 2 }) { |event| received << event }

    expect(subscription).to respond_to(:close)
    expect(transport.subscribe_args).to eq(stores: [:orders], cursor: { sequence: 2 })
    expect(received.first).to be_a(Igniter::LedgerClient::Results::ChangeEventResult)
    expect(received.first.sequence).to eq(3)
    expect(received.first.store).to eq(:orders)
  end

  it "raises clearly when a transport has no subscription boundary" do
    client = described_class.new(transport: FakeTransport.new)

    expect { client.subscribe(stores: [:orders]) { nil } }
      .to raise_error(NotImplementedError, /subscriptions/)
  end
end
