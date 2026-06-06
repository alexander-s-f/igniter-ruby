# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "ledger client transports" do
  class FakeChangefeed
    attr_reader :stores, :handler

    def subscribe(stores:, &block)
      @stores = stores
      @handler = block
      Igniter::LedgerClient::Subscription.new
    end

    def emit(event)
      handler.call(event)
    end
  end

  class FakeSseHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout
    attr_reader :requests

    def initialize(chunks)
      @chunks = chunks
      @requests = []
      @started = true
    end

    def request(request)
      @requests << request
      yield FakeSseResponse.new(@chunks)
    end

    def started?
      @started
    end

    def finish
      @started = false
    end
  end

  class FakeSseResponse
    attr_reader :code

    def initialize(chunks, code: "200")
      @chunks = chunks
      @code = code
    end

    def read_body(&block)
      @chunks.each { |chunk| block.call(chunk) }
    end
  end

  it "wraps objects exposing dispatch(envelope)" do
    target = Class.new do
      attr_reader :received

      def dispatch(envelope)
        @received = envelope
        { protocol: :igniter_store, schema_version: 1, request_id: envelope[:request_id], status: :ok, result: :accepted }
      end
    end.new

    client = Igniter::LedgerClient.wrap(target)

    expect(client.metadata_snapshot).to eq(:accepted)
    expect(target.received[:op]).to eq(:metadata_snapshot)
  end

  it "wraps objects exposing protocol.wire.dispatch(envelope)" do
    wire = Class.new do
      attr_reader :received

      def dispatch(envelope)
        @received = envelope
        { protocol: :igniter_store, schema_version: 1, request_id: envelope[:request_id], status: :ok, result: :ok }
      end
    end.new
    target = Class.new do
      define_method(:initialize) { |wire| @wire = wire }
      define_method(:protocol) { Struct.new(:wire).new(@wire) }
    end.new(wire)

    client = Igniter::LedgerClient.wrap(target)

    expect(client.metadata_snapshot).to eq(:ok)
    expect(wire.received[:op]).to eq(:metadata_snapshot)
  end

  it "subscribes through object dispatch when the target exposes changefeed" do
    feed = FakeChangefeed.new
    target = Class.new do
      define_method(:initialize) { |changefeed| @changefeed = changefeed }
      attr_reader :changefeed

      def dispatch(envelope)
        { protocol: :igniter_store, schema_version: 1, request_id: envelope[:request_id], status: :ok, result: :ok }
      end
    end.new(feed)
    client = Igniter::LedgerClient.wrap(target)
    received = []

    subscription = client.subscribe(stores: [:reminders]) { |event| received << event }
    feed.emit("cursor" => { "sequence" => 1 }, "store" => "reminders", "key" => "r1")

    expect(subscription).to respond_to(:close)
    expect(feed.stores).to eq([:reminders])
    expect(received.first.sequence).to eq(1)
    expect(received.first.store).to eq(:reminders)
  end

  it "fails clearly when object dispatch target has no changefeed" do
    target = Class.new do
      def dispatch(envelope)
        { protocol: :igniter_store, schema_version: 1, request_id: envelope[:request_id], status: :ok, result: :ok }
      end
    end.new
    client = Igniter::LedgerClient.wrap(target)

    expect { client.subscribe(stores: [:reminders]) { nil } }
      .to raise_error(NotImplementedError, /changefeed/)
  end

  it "normalizes remote HTTP endpoint root to /v1/dispatch" do
    transport = Igniter::LedgerClient::Transports::RemoteHTTP.new("http://example.test")

    expect(transport.uri.path).to eq("/v1/dispatch")
  end

  it "derives remote HTTP events URL from /v1/dispatch" do
    transport = Igniter::LedgerClient::Transports::RemoteHTTP.new("http://example.test/v1/dispatch")

    expect(transport.events_uri.to_s).to eq("http://example.test/v1/events")
  end

  it "uses explicit remote HTTP events URL when provided" do
    transport = Igniter::LedgerClient::Transports::RemoteHTTP.new(
      "http://example.test/v1/dispatch",
      events_url: "http://events.test/custom"
    )

    expect(transport.events_uri.to_s).to eq("http://events.test/custom")
  end

  it "consumes remote HTTP SSE frames and yields normalized events" do
    body = JSON.generate(cursor: { sequence: 7 }, store: "reminders", key: "r1", fact_id: "fact_1")
    fake_http = FakeSseHTTP.new(["id: 7\nevent: fact_committed\ndata: #{body}\n\n"])
    allow(Net::HTTP).to receive(:new).and_return(fake_http)
    transport = Igniter::LedgerClient::Transports::RemoteHTTP.new("http://example.test/v1/dispatch")
    client = Igniter::LedgerClient::Client.new(transport: transport)
    received = []

    subscription = client.subscribe(stores: [:reminders], cursor: { sequence: 6 }) { |event| received << event }
    sleep 0.01
    subscription.close

    request = fake_http.requests.first
    expect(request.path).to include("/v1/events")
    expect(request.path).to include("stores=reminders")
    expect(request.path).to include("cursor=6")
    expect(received.first.sequence).to eq(7)
    expect(received.first.store).to eq(:reminders)
    expect(received.first.key).to eq("r1")
  end
end
