# frozen_string_literal: true

require_relative "../../spec_helper"
require "socket"

RSpec.describe Igniter::Store::TCPAdapter do
  include Igniter::Store::WireProtocol

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    p = s.addr[1]
    s.close
    p
  end

  def make_interpreter
    Igniter::Store::Protocol::Interpreter.new(Igniter::Store::IgniterStore.new)
  end

  def make_adapter(interpreter: make_interpreter, port: free_port)
    Igniter::Store::TCPAdapter.new(interpreter: interpreter, port: port)
  end

  def base_envelope(op, packet = {})
    {
      protocol:       "igniter_store",
      schema_version: 1,
      request_id:     "tcp-#{SecureRandom.hex(4)}",
      op:             op,
      packet:         packet
    }
  end

  def send_envelope(port, envelope)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(encode_frame(JSON.generate(envelope)))
    body = read_frame(socket)
    socket.close
    JSON.parse(body, symbolize_names: true)
  end

  around(:each) do |example|
    @port       = free_port
    @interp     = make_interpreter
    @adapter    = Igniter::Store::TCPAdapter.new(interpreter: @interp, port: @port)
    @adapter.start_async
    example.run
    @adapter.stop
  end

  # ── basic connectivity ───────────────────────────────────────────────────────

  it "responds to ping-like metadata_snapshot" do
    resp = send_envelope(@port, base_envelope("metadata_snapshot"))
    expect(resp[:status].to_s).to eq("ok")
    expect(resp[:result][:schema_version]).to eq(1)
  end

  it "returns error envelope for unknown op (not raise)" do
    resp = send_envelope(@port, base_envelope("nonexistent_op"))
    expect(resp[:status].to_s).to eq("error")
    expect(resp[:error]).to be_a(String)
  end

  it "returns error envelope for wrong protocol" do
    env = base_envelope("metadata_snapshot").merge(protocol: "other_proto")
    resp = send_envelope(@port, env)
    expect(resp[:status].to_s).to eq("error")
  end

  # ── smoke: register → write → read → query ──────────────────────────────────

  it "round-trips register → write → read → query over TCP" do
    # register
    reg = send_envelope(@port, base_envelope("register_descriptor", {
      schema_version: 1, kind: :store, name: :items, key: :id,
      fields: [{ name: :label, type: :string }]
    }))
    expect(reg[:status].to_s).to eq("ok")

    # write
    write_resp = send_envelope(@port, base_envelope("write", {
      store: :items, key: "i1", value: { label: "Widget" }
    }))
    expect(write_resp[:status].to_s).to eq("ok")

    # read
    read_resp = send_envelope(@port, base_envelope("read", { store: :items, key: "i1" }))
    expect(read_resp[:status].to_s).to eq("ok")
    expect(read_resp[:result][:found]).to be true
    expect(read_resp[:result][:value][:label]).to eq("Widget")

    # query
    query_resp = send_envelope(@port, base_envelope("query", {
      store: :items, where: {}
    }))
    expect(query_resp[:status].to_s).to eq("ok")
    expect(query_resp[:result][:count]).to eq(1)
  end

  # ── sync_hub_profile ────────────────────────────────────────────────────────

  it "returns sync_hub_profile over TCP" do
    resp = send_envelope(@port, base_envelope("sync_hub_profile", {}))
    expect(resp[:status].to_s).to eq("ok")
    expect(resp[:result][:kind].to_s).to eq("sync_hub_profile")
    expect(resp[:result]).to have_key(:facts)
  end

  # ── multiple sequential requests on same connection ─────────────────────────

  it "handles multiple sequential requests on the same connection" do
    socket = TCPSocket.new("127.0.0.1", @port)

    3.times do |i|
      env = base_envelope("write", { store: :seq, key: "k#{i}", value: { n: i } })
      socket.write(encode_frame(JSON.generate(env)))
      body = read_frame(socket)
      resp = JSON.parse(body, symbolize_names: true)
      expect(resp[:status].to_s).to eq("ok")
    end

    socket.close
  end

  # ── concurrent clients ───────────────────────────────────────────────────────

  it "handles concurrent clients without errors" do
    errors  = []
    threads = 3.times.map do |i|
      Thread.new do
        resp = send_envelope(@port, base_envelope("write", {
          store: :concurrent, key: "k#{i}", value: { n: i }
        }))
        errors << "unexpected status #{resp[:status]}" unless resp[:status].to_s == "ok"
      rescue => e
        errors << e.message
      end
    end
    threads.each(&:join)
    expect(errors).to be_empty
  end

  # ── bind_address ────────────────────────────────────────────────────────────

  describe "#bind_address" do
    it "returns host:port string" do
      a = Igniter::Store::TCPAdapter.new(
        interpreter: make_interpreter, port: 17401, host: "127.0.0.1"
      )
      # Don't start it — just check the accessor
      expect(a.bind_address).to eq("127.0.0.1:17401")
      a.stop
    end

    it "returns socket path string for unix transport" do
      path = "/tmp/igniter_test_#{SecureRandom.hex(4)}.sock"
      a = Igniter::Store::TCPAdapter.new(
        interpreter: make_interpreter, host: path, transport: :unix
      )
      expect(a.bind_address).to eq(path)
      a.stop
    ensure
      File.delete(path) rescue nil
    end
  end
end
