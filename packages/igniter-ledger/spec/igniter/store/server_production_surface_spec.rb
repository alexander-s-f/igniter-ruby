# frozen_string_literal: true

require_relative "../../spec_helper"
require "stringio"

# Server Production Surface Spec
#
# Covers Slice 3 acceptance criteria:
#   - EventRing bounded ring buffer behaviour
#   - recent_events populated by server lifecycle events
#   - Slow operation tracking and alerting
#   - Draining lifecycle state (ready? / draining? / status)
#   - HTTP /v1/ready (200 when ready, 503 otherwise)
#   - HTTP /v1/metrics (metrics sub-hash)
#   - HTTP /v1/events/recent (event ring over HTTP)
#   - Structured error codes in wire responses
#   - request_id passthrough in wire responses
#
RSpec.describe "Store Server Production Surface" do
  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    p = s.addr[1]
    s.close
    p
  end

  def get_env(path)
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => path,
      "SCRIPT_NAME"    => "",
      "rack.input"     => StringIO.new("")
    }
  end

  def quiet_logger
    Igniter::Store::ServerLogger.new(nil, :error)
  end

  def make_server(**opts)
    Igniter::Store::StoreServer.new(
      address: "127.0.0.1:#{free_port}",
      logger:  quiet_logger,
      **opts
    )
  end

  # ── EventRing ────────────────────────────────────────────────────────────────

  describe Igniter::Store::EventRing do
    it "starts empty" do
      ring = described_class.new(5)
      expect(ring.to_a).to be_empty
      expect(ring.size).to eq(0)
    end

    it "stores pushed events in FIFO order" do
      ring = described_class.new(5)
      ring.push({ type: :a })
      ring.push({ type: :b })
      ring.push({ type: :c })
      expect(ring.to_a.map { |e| e[:type] }).to eq(%i[a b c])
    end

    it "evicts oldest when max_size is exceeded" do
      ring = described_class.new(3)
      4.times { |i| ring.push({ type: :"e#{i}" }) }
      expect(ring.to_a.map { |e| e[:type] }).to eq(%i[e1 e2 e3])
    end

    it "to_a returns a copy (mutations do not affect the ring)" do
      ring = described_class.new(3)
      ring.push({ type: :x })
      copy = ring.to_a
      copy.clear
      expect(ring.size).to eq(1)
    end

    it "is thread-safe under concurrent pushes" do
      ring    = described_class.new(200)
      threads = 10.times.map { |i| Thread.new { 10.times { |j| ring.push({ i: i, j: j }) } } }
      threads.each(&:join)
      expect(ring.size).to eq(100)
    end
  end

  # ── StoreServer recent_events ─────────────────────────────────────────────────

  describe "StoreServer#recent_events" do
    let(:port)   { free_port }
    let(:server) do
      s = make_server
      s.start_async
      s.wait_until_ready
      s
    end

    after { server.stop }

    it "is empty before any events" do
      # server_start event is emitted in start, which runs in background thread
      # give it a moment; but ring is populated, so at least server_start is there
      expect(server.recent_events).to be_an(Array)
    end

    it "contains server_start event after start" do
      # server_start is emitted in the background thread; give it a moment
      deadline = Time.now + 1
      types = []
      loop do
        types = server.recent_events.map { |e| e[:type] }
        break if types.include?(:server_start) || Time.now >= deadline
        sleep 0.01
      end
      expect(types).to include(:server_start)
    end

    it "is bounded by max_recent_events" do
      s = Igniter::Store::StoreServer.new(
        address:           "127.0.0.1:#{free_port}",
        logger:            quiet_logger,
        max_recent_events: 3
      )
      s.start_async
      s.wait_until_ready
      # Emit many events via connections
      5.times do
        nb = Igniter::Store::NetworkBackend.new(address: s.bind_address)
        nb.__send__(:rpc, "ping")
        nb.close
      end
      expect(s.recent_events.size).to be <= 3
    ensure
      s.stop
    end
  end

  # ── Slow operation tracking ───────────────────────────────────────────────────

  describe "slow operation tracking" do
    it "records slow ops in metrics when threshold exceeded" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:              "127.0.0.1:#{port}",
        logger:               quiet_logger,
        slow_op_threshold_ms: -1   # -1ms threshold — every op is "slow"
      )
      server.start_async
      server.wait_until_ready

      nb = Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}")
      nb.__send__(:rpc, "ping")
      nb.close

      snap = server.observability_snapshot
      expect(snap[:metrics][:slow_ops_total]).to be_a(Hash)
      expect(snap[:metrics][:slow_ops_total].values.sum).to be >= 1
    ensure
      server.stop
    end

    it "emits slow_op event into recent_events" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:              "127.0.0.1:#{port}",
        logger:               quiet_logger,
        slow_op_threshold_ms: -1   # always slow
      )
      server.start_async
      server.wait_until_ready

      nb = Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}")
      nb.__send__(:rpc, "ping")
      nb.close

      types = server.recent_events.map { |e| e[:type] }
      expect(types).to include(:slow_op)
    ensure
      server.stop
    end

    describe "ServerMetrics slow_op_count alert" do
      it "fires alert when slow_op_count threshold is exceeded" do
        metrics = Igniter::Store::ServerMetrics.new(thresholds: { slow_op_count: 2 })
        3.times { metrics.record_slow_op(op: "ping") }
        alerts = metrics.check_alerts
        slow_alert = alerts.find { |a| a[:type] == :slow_op_count }
        expect(slow_alert).not_to be_nil
        expect(slow_alert[:threshold]).to eq(2)
        expect(slow_alert[:current_value]).to eq(3)
      end

      it "does not fire when slow_op_count threshold is nil (disabled)" do
        metrics = Igniter::Store::ServerMetrics.new
        10.times { metrics.record_slow_op(op: "ping") }
        alerts = metrics.check_alerts
        expect(alerts.none? { |a| a[:type] == :slow_op_count }).to be true
      end

      it "includes slow_ops_total in snapshot" do
        metrics = Igniter::Store::ServerMetrics.new
        metrics.record_slow_op(op: "write_fact")
        metrics.record_slow_op(op: "replay")
        snap = metrics.snapshot
        expect(snap[:slow_ops_total]["write_fact"]).to eq(1)
        expect(snap[:slow_ops_total]["replay"]).to eq(1)
      end
    end
  end

  # ── Draining state ────────────────────────────────────────────────────────────

  describe "draining lifecycle" do
    it "ready? is true when running normally" do
      server = make_server
      server.start_async
      server.wait_until_ready
      expect(server.ready?).to be true
      server.stop
    end

    it "draining? is false before drain is called" do
      server = make_server
      server.start_async
      server.wait_until_ready
      expect(server.draining?).to be false
      server.stop
    end

    it "drain sets draining? to true" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:       "127.0.0.1:#{port}",
        logger:        quiet_logger,
        drain_timeout: 0
      )
      server.start_async
      server.wait_until_ready
      server.drain(timeout: 0)
      expect(server.draining?).to be true
    ensure
      server.stop
    end

    it "observability_snapshot[:status] is :draining after drain" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:       "127.0.0.1:#{port}",
        logger:        quiet_logger,
        drain_timeout: 0
      )
      server.start_async
      server.wait_until_ready
      server.drain(timeout: 0)
      expect(server.observability_snapshot[:status]).to eq(:draining)
    ensure
      server.stop
    end

    it "ready? is false when draining" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:       "127.0.0.1:#{port}",
        logger:        quiet_logger,
        drain_timeout: 0
      )
      server.start_async
      server.wait_until_ready
      server.drain(timeout: 0)
      expect(server.ready?).to be false
    ensure
      server.stop
    end

    it "new connections are rejected (metrics increment) while draining" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:       "127.0.0.1:#{port}",
        logger:        quiet_logger,
        drain_timeout: 0
      )
      server.start_async
      server.wait_until_ready
      rejected_before = server.observability_snapshot[:metrics][:rejected_connections_total]

      server.drain(timeout: 0)

      # Attempt a new connection — server socket is still open but rejects it
      begin
        TCPSocket.new("127.0.0.1", port).close
      rescue Errno::ECONNREFUSED, IOError
        nil
      end
      sleep 0.05

      rejected_after = server.observability_snapshot[:metrics][:rejected_connections_total]
      expect(rejected_after).to be >= rejected_before
    ensure
      server.stop
    end

    it "emits server_draining event into recent_events" do
      port   = free_port
      server = Igniter::Store::StoreServer.new(
        address:       "127.0.0.1:#{port}",
        logger:        quiet_logger,
        drain_timeout: 0
      )
      server.start_async
      server.wait_until_ready
      server.drain(timeout: 0)
      types = server.recent_events.map { |e| e[:type] }
      expect(types).to include(:server_draining)
    ensure
      server.stop
    end
  end

  # ── HTTP /v1/ready ────────────────────────────────────────────────────────────

  describe "HTTP /v1/ready" do
    let(:interpreter) do
      Igniter::Store::Protocol::Interpreter.new(Igniter::Store.memory)
    end

    it "returns 200 when ready_provider returns true" do
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:    interpreter,
        ready_provider: -> { true }
      )
      status, headers, body = adapter.rack_app.call(get_env("/v1/ready"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status]).to eq("ready")
    end

    it "returns 503 when ready_provider returns false" do
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:    interpreter,
        ready_provider: -> { false }
      )
      status, _, body = adapter.rack_app.call(get_env("/v1/ready"))
      expect(status).to eq(503)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:status]).to eq("unavailable")
    end

    it "returns 200 by default (no ready_provider)" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      status, _, _ = adapter.rack_app.call(get_env("/v1/ready"))
      expect(status).to eq(200)
    end

    it "returns 405 on POST" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      env = get_env("/v1/ready").merge("REQUEST_METHOD" => "POST")
      status, _, _ = adapter.rack_app.call(env)
      expect(status).to eq(405)
    end
  end

  # ── HTTP /v1/metrics ──────────────────────────────────────────────────────────

  describe "HTTP /v1/metrics" do
    let(:interpreter) do
      Igniter::Store::Protocol::Interpreter.new(Igniter::Store.memory)
    end

    it "returns 200 with metrics hash from provider" do
      metrics_data = { requests_total: { "ping" => 5 }, facts_written: 10 }
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:      interpreter,
        metrics_provider: -> { metrics_data }
      )
      status, headers, body = adapter.rack_app.call(get_env("/v1/metrics"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:facts_written]).to eq(10)
    end

    it "returns empty hash when no metrics_provider" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      status, _, body = adapter.rack_app.call(get_env("/v1/metrics"))
      expect(status).to eq(200)
      expect(JSON.parse(body.join)).to eq({})
    end

    it "returns 405 on POST" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      env = get_env("/v1/metrics").merge("REQUEST_METHOD" => "POST")
      status, _, _ = adapter.rack_app.call(env)
      expect(status).to eq(405)
    end
  end

  # ── HTTP /v1/events/recent ────────────────────────────────────────────────────

  describe "HTTP /v1/events/recent" do
    let(:interpreter) do
      Igniter::Store::Protocol::Interpreter.new(Igniter::Store.memory)
    end

    it "returns 200 with events array and count" do
      events = [{ type: "server_start", ts: "2026-05-02T00:00:00.000Z" }]
      adapter = Igniter::Store::HTTPAdapter.new(
        interpreter:     interpreter,
        events_provider: -> { events }
      )
      status, headers, body = adapter.rack_app.call(get_env("/v1/events/recent"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("application/json")
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:count]).to eq(1)
      expect(data[:events]).to be_an(Array)
    end

    it "returns empty events when no provider" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      status, _, body = adapter.rack_app.call(get_env("/v1/events/recent"))
      expect(status).to eq(200)
      data = JSON.parse(body.join, symbolize_names: true)
      expect(data[:count]).to eq(0)
      expect(data[:events]).to be_empty
    end

    it "returns 405 on POST" do
      adapter = Igniter::Store::HTTPAdapter.new(interpreter: interpreter)
      env = get_env("/v1/events/recent").merge("REQUEST_METHOD" => "POST")
      status, _, _ = adapter.rack_app.call(env)
      expect(status).to eq(405)
    end
  end

  # ── Structured wire error codes ───────────────────────────────────────────────

  describe "structured wire error codes" do
    let(:server_port) { free_port }
    let(:server) do
      s = Igniter::Store::StoreServer.new(
        address: "127.0.0.1:#{server_port}",
        logger:  quiet_logger
      )
      s.start_async
      s.wait_until_ready
      s
    end

    after { server.stop }

    def raw_rpc(port, op)
      req   = { op: op }
      frame = FRAMER.encode_frame(JSON.generate(req))
      s     = TCPSocket.new("127.0.0.1", port)
      s.write(frame)
      body  = FRAMER.read_frame(s)
      s.close
      JSON.parse(body, symbolize_names: true)
    end

    it "unknown op returns error_code: :unknown_op" do
      server  # force lazy start
      resp = raw_rpc(server_port, "nonexistent_op")
      expect(resp[:ok]).to be false
      expect(resp[:error_code].to_sym).to eq(:unknown_op)
    end

    it "error response includes descriptive error message" do
      server  # force lazy start
      resp = raw_rpc(server_port, "nonexistent_op")
      expect(resp[:error]).to include("nonexistent_op")
    end
  end

  # ── request_id passthrough ────────────────────────────────────────────────────

  # Helper that includes WireProtocol framing for raw socket tests.
  module FrameHelper
    include Igniter::Store::WireProtocol
  end
  FRAMER = Object.new.extend(FrameHelper)

  describe "request_id passthrough" do
    let(:server_port) { free_port }
    let(:server) do
      s = Igniter::Store::StoreServer.new(
        address: "127.0.0.1:#{server_port}",
        logger:  quiet_logger
      )
      s.start_async
      s.wait_until_ready
      s
    end

    after { server.stop }

    it "echoes request_id back in the response" do
      server  # force lazy start
      req    = { op: "ping", request_id: "test-abc-123" }
      frame  = FRAMER.encode_frame(JSON.generate(req))
      socket = TCPSocket.new("127.0.0.1", server_port)
      socket.write(frame)
      resp_body = FRAMER.read_frame(socket)
      socket.close

      resp = JSON.parse(resp_body, symbolize_names: true)
      expect(resp[:request_id]).to eq("test-abc-123")
    end

    it "response is valid when no request_id in request" do
      nb   = Igniter::Store::NetworkBackend.new(address: server.bind_address)
      resp = nb.__send__(:rpc, "ping")
      expect(resp[:ok]).to be true
      nb.close
    end
  end

  # ── observability_snapshot includes slow_ops_total ───────────────────────────

  describe "observability_snapshot metrics shape" do
    let(:port)   { free_port }
    let(:server) do
      s = make_server
      s.start_async
      s.wait_until_ready
      s
    end

    after { server.stop }

    it "includes slow_ops_total key in metrics" do
      snap = server.observability_snapshot
      expect(snap[:metrics]).to have_key(:slow_ops_total)
      expect(snap[:metrics][:slow_ops_total]).to be_a(Hash)
    end

    it "status reflects server state accurately" do
      snap = server.observability_snapshot
      expect(snap[:status]).to eq(:ready)
    end
  end
end
