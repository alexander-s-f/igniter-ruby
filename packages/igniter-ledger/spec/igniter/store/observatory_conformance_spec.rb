# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Observatory Conformance Smoke
#
# Proves that the canonical observability snapshot shape is consistent across
# every access plane:
#
#   Protocol::Interpreter → WireEnvelope → MCPAdapter → HTTP /v1/status
#
# "Consistent" means the common fields (schema_version, status, storage,
# alerts) agree across planes even if server-level fields (metrics, uptime_ms,
# server) are nil at the protocol level.
RSpec.describe "Observatory conformance" do
  def envelope(op, packet = {})
    {
      protocol:       :igniter_store,
      schema_version: 1,
      request_id:     "req_#{SecureRandom.hex(4)}",
      op:             op,
      packet:         packet
    }
  end

  def get_env(path)
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => path,
      "SCRIPT_NAME"    => "",
      "rack.input"     => StringIO.new("")
    }
  end

  # ── In-memory backend (protocol level) ──────────────────────────────────────

  describe "in-memory store" do
    let(:store) { Igniter::Store.memory }
    let(:proto) { Igniter::Store::Protocol::Interpreter.new(store) }
    let(:wire)  { proto.wire }
    let(:mcp)   { Igniter::Store::MCPAdapter.new(store) }

    after { store.close rescue nil }

    describe "Protocol::Interpreter#observability_snapshot" do
      it "returns canonical shape with expected keys" do
        snap = proto.observability_snapshot
        expect(snap[:schema_version]).to eq(1)
        expect(snap[:generated_at]).to   match(/\d{4}-\d{2}-\d{2}T/)
        expect(snap[:status]).to         eq(:ready)
        expect(snap[:uptime_ms]).to      be_nil
        expect(snap[:metrics]).to        be_nil
        expect(snap[:alerts]).to         be_an(Array)
        expect(snap[:storage]).to        be_nil
        expect(snap[:server]).to         be_nil
      end

      it "storage is nil for in-memory backend" do
        expect(proto.observability_snapshot[:storage]).to be_nil
      end

      it "alerts is empty array when no thresholds breached" do
        expect(proto.observability_snapshot[:alerts]).to be_empty
      end
    end

    describe "WireEnvelope dispatch: observability_snapshot" do
      it "returns status :ok with canonical shape" do
        resp = wire.dispatch(envelope(:observability_snapshot))
        expect(resp[:status]).to             eq(:ok)
        expect(resp[:result][:schema_version]).to eq(1)
        expect(resp[:result][:status]).to        eq(:ready)
        expect(resp[:result][:storage]).to        be_nil
        expect(resp[:result][:alerts]).to         be_an(Array)
      end

      it "result agrees with direct interpreter call" do
        p_snap = proto.observability_snapshot
        w_resp = wire.dispatch(envelope(:observability_snapshot))
        expect(w_resp[:result][:schema_version]).to eq(p_snap[:schema_version])
        expect(w_resp[:result][:status]).to         eq(p_snap[:status])
        expect(w_resp[:result][:storage]).to        eq(p_snap[:storage])
        expect(w_resp[:result][:alerts]).to         eq(p_snap[:alerts])
      end
    end

    describe "MCPAdapter :observability_snapshot tool" do
      it "is listed in tool_list" do
        names = mcp.tool_list.map { |t| t[:name] }
        expect(names).to include("observability_snapshot")
      end

      it "returns status :ok with canonical shape" do
        resp = mcp.call_tool(:observability_snapshot)
        expect(resp[:status]).to              eq(:ok)
        expect(resp[:result][:schema_version]).to eq(1)
        expect(resp[:result][:status]).to        eq(:ready)
        expect(resp[:result][:storage]).to        be_nil
      end

      it "source_protocol_op is :observability_snapshot" do
        resp = mcp.call_tool(:observability_snapshot)
        expect(resp[:source_protocol_op]).to eq(:observability_snapshot)
      end

      it "MCP result agrees with protocol on shared fields" do
        p_snap = proto.observability_snapshot
        m_resp = mcp.call_tool(:observability_snapshot)[:result]
        expect(m_resp[:schema_version]).to eq(p_snap[:schema_version])
        expect(m_resp[:status]).to         eq(p_snap[:status])
        expect(m_resp[:storage]).to        eq(p_snap[:storage])
        expect(m_resp[:alerts]).to         eq(p_snap[:alerts])
      end
    end

    describe "HTTP /v1/status (standalone adapter)" do
      let(:adapter) { Igniter::Store::HTTPAdapter.new(interpreter: proto) }
      let(:app)     { adapter.rack_app }

      it "GET /v1/status returns 200 with canonical shape" do
        status, headers, body = app.call(get_env("/v1/status"))
        expect(status).to eq(200)
        expect(headers["Content-Type"]).to eq("application/json")

        data = JSON.parse(body.join, symbolize_names: true)
        expect(data[:schema_version]).to eq(1)
        expect(data[:status]).to         eq("ready")
        expect(data[:storage]).to        be_nil
        expect(data[:alerts]).to         be_an(Array)
      end

      it "GET /v1/status result agrees with protocol observability_snapshot" do
        p_snap = proto.observability_snapshot
        _, _, body = app.call(get_env("/v1/status"))
        data = JSON.parse(body.join, symbolize_names: true)

        expect(data[:schema_version]).to eq(p_snap[:schema_version])
        expect(data[:status].to_s).to    eq(p_snap[:status].to_s)
        expect(data[:storage]).to        eq(p_snap[:storage])
      end

      it "GET /v1/status rejects POST" do
        env = get_env("/v1/status").merge("REQUEST_METHOD" => "POST")
        status, _, _ = app.call(env)
        expect(status).to eq(405)
      end

      it "GET /v1/health still returns compact health (backward compat)" do
        status, _, body = app.call(get_env("/v1/health"))
        expect(status).to eq(200)
        data = JSON.parse(body.join, symbolize_names: true)
        expect(data[:status]).to   eq("ready")
        expect(data[:protocol]).to eq("igniter_store")
      end
    end

    describe "HTTP /v1/status with status_provider" do
      it "uses status_provider data when set" do
        custom_snapshot = {
          schema_version: 1,
          generated_at:   Time.now.iso8601(3),
          status:         :ready,
          uptime_ms:      9999,
          metrics:        { requests_total: {}, facts_written: 0, facts_replayed: 0,
                            bytes_in: 0, bytes_out: 0, active_connections: 0,
                            accepted_connections_total: 0, closed_connections_total: 0,
                            rejected_connections_total: 0, subscription_count: 0,
                            errors_total: {} },
          alerts:         [],
          storage:        nil,
          server:         { backend: "memory", transport: "tcp", bind_address: "127.0.0.1:7400", last_error: nil }
        }
        adapter = Igniter::Store::HTTPAdapter.new(
          interpreter:     proto,
          status_provider: -> { custom_snapshot }
        )
        _, _, body = adapter.rack_app.call(get_env("/v1/status"))
        data = JSON.parse(body.join, symbolize_names: true)
        expect(data[:uptime_ms]).to eq(9999)
        expect(data[:server]).not_to be_nil
        expect(data[:server][:backend]).to eq("memory")
      end
    end
  end

  # ── Segmented backend (storage alerts) ──────────────────────────────────────

  describe "segmented backend with alert thresholds" do
    let(:tmpdir) { Dir.mktmpdir("observatory-spec-") }
    let(:store)  { Igniter::Store.segmented(tmpdir) }

    after do
      store.close rescue nil
      FileUtils.rm_rf(tmpdir)
    end

    it "alerts is empty when no thresholds breached" do
      store.write(store: :x, key: "k1", value: { v: 1 })
      proto = Igniter::Store::Protocol::Interpreter.new(store)
      expect(proto.observability_snapshot[:alerts]).to be_empty
    end

    it "fires storage_byte_size alert when threshold is set low" do
      store.write(store: :x, key: "k1", value: { payload: "x" * 100 })
      store.instance_variable_get(:@backend).checkpoint!

      proto = Igniter::Store::Protocol::Interpreter.new(
        store, alert_thresholds: { storage_byte_size: 1 }
      )
      snap = proto.observability_snapshot
      bs_alert = snap[:alerts].find { |a| a[:type] == :storage_byte_size }
      expect(bs_alert).not_to be_nil
      expect(bs_alert[:threshold]).to eq(1)
      expect(bs_alert[:current_value]).to be > 1
    end

    it "observability_snapshot includes storage section for segmented backend" do
      store.write(store: :readings, key: "k1", value: { v: 1 })
      proto = Igniter::Store::Protocol::Interpreter.new(store)
      snap  = proto.observability_snapshot
      expect(snap[:storage]).not_to be_nil
      expect(snap[:storage]["stores"]).to have_key("readings")
    end

    it "Wire and MCP agree on storage presence" do
      store.write(store: :readings, key: "k1", value: { v: 1 })
      proto = Igniter::Store::Protocol::Interpreter.new(store)
      wire  = proto.wire
      mcp   = Igniter::Store::MCPAdapter.new(store)

      p_snap = proto.observability_snapshot
      w_resp = wire.dispatch(envelope(:observability_snapshot))
      m_resp = mcp.call_tool(:observability_snapshot)

      expect(p_snap[:storage]).not_to be_nil
      expect(w_resp[:result][:storage]).not_to be_nil
      expect(m_resp[:result][:storage]).not_to be_nil

      # All three see the same storage key set
      p_stores = p_snap[:storage]["stores"].keys.sort
      w_stores = w_resp[:result][:storage]["stores"].keys.sort
      m_stores = m_resp[:result][:storage]["stores"].keys.sort
      expect(w_stores).to eq(p_stores)
      expect(m_stores).to eq(p_stores)
    end
  end

  # ── StoreServer#observability_snapshot canonical shape ──────────────────────

  describe "StoreServer#observability_snapshot" do
    def free_port
      s = TCPServer.new("127.0.0.1", 0)
      p = s.addr[1]
      s.close
      p
    end

    let(:port) { free_port }
    let(:server) do
      s = Igniter::Store::StoreServer.new(
        address: "127.0.0.1:#{port}",
        logger:  Igniter::Store::ServerLogger.new(nil, :error)
      )
      s.start_async
      s.wait_until_ready
      s
    end

    after { server.stop }

    it "returns canonical shape with all top-level keys" do
      snap = server.observability_snapshot
      expected = %i[schema_version generated_at status uptime_ms metrics alerts storage server]
      expected.each { |k| expect(snap).to have_key(k) }
    end

    it "status is :ready when server is running" do
      expect(server.observability_snapshot[:status]).to eq(:ready)
    end

    it "uptime_ms is positive" do
      expect(server.observability_snapshot[:uptime_ms]).to be > 0
    end

    it "server sub-hash includes backend, transport, bind_address" do
      srv = server.observability_snapshot[:server]
      expect(srv[:backend]).to      eq("memory")
      expect(srv[:transport]).to    eq("tcp")
      expect(srv[:bind_address]).to eq("127.0.0.1:#{port}")
    end

    it "metrics sub-hash includes counters" do
      metrics = server.observability_snapshot[:metrics]
      expect(metrics[:requests_total]).to  be_a(Hash)
      expect(metrics[:errors_total]).to    be_a(Hash)
      expect(metrics[:facts_written]).to   be_a(Integer)
    end

    it "storage is nil for memory backend" do
      expect(server.observability_snapshot[:storage]).to be_nil
    end

    it "alerts is an Array" do
      expect(server.observability_snapshot[:alerts]).to be_an(Array)
    end

    it "server_status op uses observability_snapshot" do
      server  # ensure server is started
      nb = Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}")
      resp = nb.__send__(:rpc, "server_status")
      expect(resp[:ok]).to             be true
      expect(resp[:schema_version]).to eq(1)
      expect(resp[:status]).not_to     be_nil
      expect(resp[:metrics]).not_to    be_nil
      expect(resp[:server]).not_to     be_nil
      nb.close
    end
  end

  # ── MCPAdapter defaults include observability_snapshot ──────────────────────

  describe "MCPAdapter default READ_TOOLS" do
    it "includes observability_snapshot" do
      expect(Igniter::Store::MCPAdapter::READ_TOOLS).to include(:observability_snapshot)
    end

    it "TOOL_TO_OP maps observability_snapshot → :observability_snapshot" do
      expect(Igniter::Store::MCPAdapter::TOOL_TO_OP[:observability_snapshot]).to eq(:observability_snapshot)
    end
  end
end
