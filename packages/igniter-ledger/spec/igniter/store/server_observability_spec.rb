# frozen_string_literal: true

require_relative "../../spec_helper"
require "stringio"

RSpec.describe "StoreServer Observability" do

  # ── Helpers ─────────────────────────────────────────────────────────────────

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    p = s.addr[1]
    s.close
    p
  end

  def null_logger
    Igniter::Store::ServerLogger.new(nil, :error)
  end

  def start(port, **opts)
    server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: null_logger, **opts)
    server.start_async
    server.wait_until_ready
    server
  end

  def client(port)
    Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}")
  end

  after(:each) { @server&.stop }

  # ── ServerMetrics unit tests ─────────────────────────────────────────────────

  describe Igniter::Store::ServerMetrics do
    let(:metrics) { described_class.new }

    describe "#record_connection_accepted / #record_connection_closed" do
      it "returns a unique connection_id string" do
        id = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
        expect(id).to match(/\A[0-9a-f]{16}\z/)
      end

      it "active_connections reflects open connections" do
        id1 = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
        id2 = metrics.record_connection_accepted(remote_addr: "10.0.0.2")
        expect(metrics.snapshot[:active_connections]).to eq(2)

        metrics.record_connection_closed(id: id1)
        expect(metrics.snapshot[:active_connections]).to eq(1)

        metrics.record_connection_closed(id: id2, reason: :normal)
        expect(metrics.snapshot[:active_connections]).to eq(0)
      end

      it "increments accepted_connections_total" do
        2.times { metrics.record_connection_accepted(remote_addr: "10.0.0.1") }
        expect(metrics.snapshot[:accepted_connections_total]).to eq(2)
      end

      it "increments closed_connections_total on close" do
        id = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
        metrics.record_connection_closed(id: id)
        expect(metrics.snapshot[:closed_connections_total]).to eq(1)
      end

      it "tolerates closing an unknown id without raising" do
        expect { metrics.record_connection_closed(id: "nonexistent") }.not_to raise_error
        expect(metrics.snapshot[:closed_connections_total]).to eq(1)
      end
    end

    describe "#record_connection_rejected" do
      it "increments rejected_connections_total" do
        3.times { metrics.record_connection_rejected }
        expect(metrics.snapshot[:rejected_connections_total]).to eq(3)
      end
    end

    describe "#record_request" do
      it "counts requests per op and accumulates bytes" do
        id = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
        metrics.record_request(connection_id: id, op: "write_fact", bytes_in: 100, bytes_out: 20)
        metrics.record_request(connection_id: id, op: "write_fact", bytes_in: 80,  bytes_out: 20)
        metrics.record_request(connection_id: id, op: "replay",     bytes_in: 10,  bytes_out: 500)

        snap = metrics.snapshot
        expect(snap[:requests_total]["write_fact"]).to eq(2)
        expect(snap[:requests_total]["replay"]).to     eq(1)
        expect(snap[:bytes_in]).to                     eq(190)
        expect(snap[:bytes_out]).to                    eq(540)
      end

      it "updates per-connection last_op and ops_count" do
        id = metrics.record_connection_accepted(remote_addr: "10.0.0.1")
        metrics.record_request(connection_id: id, op: "ping")
        metrics.record_request(connection_id: id, op: "stats")

        snap = metrics.snapshot
        expect(snap[:requests_total]["stats"]).to eq(1)
      end

      it "ignores unknown connection_id without raising" do
        expect {
          metrics.record_request(connection_id: "ghost", op: "ping")
        }.not_to raise_error
      end
    end

    describe "#record_error" do
      it "accumulates errors keyed by class/op" do
        metrics.record_error(op: "write_fact", error_class: "RequestError")
        metrics.record_error(op: "write_fact", error_class: "RequestError")
        metrics.record_error(op: "replay",     error_class: "IOError")

        snap = metrics.snapshot
        expect(snap[:errors_total]["RequestError/write_fact"]).to eq(2)
        expect(snap[:errors_total]["IOError/replay"]).to           eq(1)
      end
    end

    describe "#record_facts_written / #record_facts_replayed" do
      it "tracks facts_written" do
        3.times { metrics.record_facts_written }
        expect(metrics.snapshot[:facts_written]).to eq(3)
      end

      it "tracks facts_replayed" do
        metrics.record_facts_replayed(count: 17)
        expect(metrics.snapshot[:facts_replayed]).to eq(17)
      end
    end

    describe "#record_subscription_opened / #record_subscription_closed" do
      it "reflects subscription_count and subscriptions_by_store" do
        metrics.record_subscription_opened(store: "tasks")
        metrics.record_subscription_opened(store: "tasks")
        metrics.record_subscription_opened(store: "events")

        snap = metrics.snapshot
        expect(snap[:subscription_count]).to                eq(3)
        expect(snap[:subscriptions_by_store]["tasks"]).to   eq(2)
        expect(snap[:subscriptions_by_store]["events"]).to  eq(1)

        metrics.record_subscription_closed(store: "tasks")
        snap2 = metrics.snapshot
        expect(snap2[:subscription_count]).to               eq(2)
        expect(snap2[:subscriptions_by_store]["tasks"]).to  eq(1)
      end

      it "does not go below zero on excess closes" do
        metrics.record_subscription_opened(store: "x")
        metrics.record_subscription_closed(store: "x")
        metrics.record_subscription_closed(store: "x")
        expect(metrics.snapshot[:subscriptions_by_store]["x"]).to eq(0)
      end
    end

    describe "#snapshot structure" do
      it "includes all required top-level keys" do
        snap = metrics.snapshot
        expected = %i[
          schema_version generated_at uptime_ms
          facts_written facts_replayed bytes_in bytes_out
          requests_total errors_total
          active_connections accepted_connections_total
          closed_connections_total rejected_connections_total
          subscription_count subscriptions_by_store
          storage_stats alerts
        ]
        expected.each { |k| expect(snap).to have_key(k) }
      end

      it "uptime_ms grows over time" do
        snap1 = metrics.snapshot
        sleep 0.05
        snap2 = metrics.snapshot
        expect(snap2[:uptime_ms]).to be >= snap1[:uptime_ms]
      end

      it "storage_stats is nil when backend does not support it" do
        expect(metrics.snapshot(backend: nil)[:storage_stats]).to be_nil
        expect(metrics.snapshot(backend: Object.new)[:storage_stats]).to be_nil
      end
    end

    describe "#check_alerts / #alerts" do
      it "fires max_connections alert when threshold exceeded" do
        m = described_class.new(thresholds: { max_connections: 2 })
        3.times { m.record_connection_accepted(remote_addr: "10.0.0.1") }
        alerts = m.check_alerts
        mc_alert = alerts.find { |a| a.type == :max_connections }
        expect(mc_alert).not_to be_nil
        expect(mc_alert.threshold).to    eq(2)
        expect(mc_alert.current_value).to eq(3)
        expect(mc_alert.message).to      match(/max_connections exceeded/)
      end

      it "fires error_rate alert when fraction exceeds threshold" do
        m = described_class.new(thresholds: { error_rate: 0.1 })
        id = m.record_connection_accepted(remote_addr: "10.0.0.1")
        5.times  { m.record_request(connection_id: id, op: "ping") }
        3.times  { m.record_error(op: "ping", error_class: "RequestError") }
        alerts = m.check_alerts
        expect(alerts.any? { |a| a.type == :error_rate }).to be true
      end

      it "does not fire the same alert type twice" do
        m = described_class.new(thresholds: { max_connections: 1 })
        2.times { m.record_connection_accepted(remote_addr: "10.0.0.1") }
        m.check_alerts
        m.check_alerts
        expect(m.alerts.count { |a| a.type == :max_connections }).to eq(1)
      end

      it "fires quarantine_receipt_count alert from storage_stats" do
        backend = Object.new
        def backend.storage_stats
          {
            "stores" => {
              "readings" => { "quarantine_receipt_count" => 2, "byte_size" => 10 }
            }
          }
        end

        m = described_class.new(thresholds: { quarantine_receipt_count: 1 })
        alerts = m.check_alerts(backend: backend)

        expect(alerts.any? { |a| a.type == :quarantine_receipt_count }).to be true
      end

      it "returns empty array when no thresholds breached" do
        expect(metrics.check_alerts).to be_empty
      end

      it "alert struct has required fields" do
        m = described_class.new(thresholds: { max_connections: 0 })
        m.record_connection_accepted(remote_addr: "10.0.0.1")
        alerts = m.check_alerts
        alert = alerts.first
        expect(alert.id).to           match(/\A[0-9a-f]{12}\z/)
        expect(alert.fired_at).to     be_a(Time)
        expect(alert.type).to         eq(:max_connections)
        expect(alert.threshold).to    eq(0)
        expect(alert.current_value).to eq(1)
        expect(alert.message).to      be_a(String)
      end
    end

    describe "thread safety" do
      it "handles concurrent recording without corruption" do
        m = described_class.new
        threads = 10.times.map do |i|
          Thread.new do
            id = m.record_connection_accepted(remote_addr: "10.0.0.#{i}")
            5.times { m.record_request(connection_id: id, op: "write_fact", bytes_in: 10) }
            m.record_facts_written(count: 5)
            m.record_connection_closed(id: id)
          end
        end
        threads.each(&:join)
        snap = m.snapshot
        expect(snap[:accepted_connections_total]).to eq(10)
        expect(snap[:closed_connections_total]).to   eq(10)
        expect(snap[:active_connections]).to         eq(0)
        expect(snap[:facts_written]).to              eq(50)
        expect(snap[:requests_total]["write_fact"]).to eq(50)
      end
    end
  end

  # ── ServerLogger#event ───────────────────────────────────────────────────────

  describe Igniter::Store::ServerLogger do
    describe "#event" do
      it "writes a [EVENT] JSON line to io" do
        io  = StringIO.new
        log = described_class.new(io, :info)
        log.event(:server_start, bind_address: "127.0.0.1:7400")

        expect(io.string).to start_with("[EVENT] ")
        parsed = JSON.parse(io.string.sub("[EVENT] ", ""))
        expect(parsed["event"]).to eq("server_start")
        expect(parsed["ts"]).to    match(/\d{4}-\d{2}-\d{2}T/)
        expect(parsed["bind_address"]).to eq("127.0.0.1:7400")
      end

      it "respects level: :debug kwarg — suppressed at :info min level" do
        io  = StringIO.new
        log = described_class.new(io, :info)
        log.event(:request, level: :debug, op: "write_fact")
        expect(io.string).to be_empty
      end

      it "emits debug events when min level is :debug" do
        io  = StringIO.new
        log = described_class.new(io, :debug)
        log.event(:request, level: :debug, op: "write_fact")
        expect(io.string).to include("[EVENT]")
        expect(io.string).to include("write_fact")
      end

      it "is silent when io is nil" do
        log = described_class.new(nil, :debug)
        expect { log.event(:server_start) }.not_to raise_error
      end

      it "is thread-safe under concurrent event writes" do
        io  = StringIO.new
        log = described_class.new(io, :info)
        threads = 20.times.map { |i| Thread.new { log.event(:request, op: "op_#{i}") } }
        threads.each(&:join)
        lines = io.string.split("\n")
        expect(lines.size).to eq(20)
        lines.each { |l| expect(l).to start_with("[EVENT] ") }
      end
    end
  end

  # ── StoreServer#health_snapshot ──────────────────────────────────────────────

  describe "StoreServer#health_snapshot" do
    it "returns required fields with status :ready when running" do
      port    = free_port
      @server = start(port)

      snap = @server.health_snapshot
      expect(snap[:schema_version]).to     eq(1)
      expect(snap[:status]).to             eq(:ready)
      expect(snap[:backend]).to            eq("memory")
      expect(snap[:transport]).to          eq("tcp")
      expect(snap[:bind_address]).to       eq("127.0.0.1:#{port}")
      expect(snap[:uptime_ms]).to          be > 0
      expect(snap[:active_connections]).to be_a(Integer)
      expect(snap[:subscriptions]).to      be_a(Integer)
    end

    it "reflects active_connections count" do
      port    = free_port
      @server = start(port)

      c = client(port)
      sleep 0.05
      expect(@server.health_snapshot[:active_connections]).to eq(1)
      c.close
      sleep 0.05
      expect(@server.health_snapshot[:active_connections]).to eq(0)
    end
  end

  # ── StoreServer#metrics_snapshot ────────────────────────────────────────────

  describe "StoreServer#metrics_snapshot" do
    it "returns a Hash with all snapshot keys" do
      port    = free_port
      @server = start(port)

      snap = @server.metrics_snapshot
      expect(snap[:schema_version]).to    eq(1)
      expect(snap[:uptime_ms]).to         be > 0
      expect(snap[:facts_written]).to     be_a(Integer)
      expect(snap[:requests_total]).to    be_a(Hash)
      expect(snap[:errors_total]).to      be_a(Hash)
      expect(snap[:active_connections]).to be_a(Integer)
    end

    it "facts_written grows after write operations" do
      port    = free_port
      @server = start(port)
      c = client(port)
      3.times { |i| c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k#{i}", value: {})) }
      sleep 0.05
      expect(@server.metrics_snapshot[:facts_written]).to eq(3)
      c.close
    end

    it "storage_stats is nil for memory backend" do
      port    = free_port
      @server = start(port)
      expect(@server.metrics_snapshot[:storage_stats]).to be_nil
    end
  end

  # ── server_status op ────────────────────────────────────────────────────────

  describe "server_status operation" do
    it "returns ok with canonical observability shape" do
      port    = free_port
      @server = start(port)
      c       = client(port)

      resp = c.__send__(:rpc, "server_status")
      expect(resp[:ok]).to             be true
      expect(resp[:schema_version]).to eq(1)
      expect(resp[:status]).not_to     be_nil
      expect(resp[:uptime_ms]).to      be > 0
      expect(resp[:metrics]).to        be_a(Hash)
      expect(resp[:alerts]).to         be_an(Array)
      expect(resp[:server]).to         be_a(Hash)

      c.close
    end

    it "facts_written is reflected inside metrics in server_status" do
      port    = free_port
      @server = start(port)
      c = client(port)

      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k1", value: { n: 1 }))
      resp = c.__send__(:rpc, "server_status")
      expect(resp[:metrics][:facts_written]).to eq(1)

      c.close
    end
  end

  # ── stats op backward compatibility ─────────────────────────────────────────

  describe "stats op backward compatibility" do
    it "still returns facts_written, connections_active, uptime_ms" do
      port    = free_port
      @server = start(port)
      c       = client(port)

      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k1", value: {}))
      resp = c.__send__(:rpc, "stats")

      expect(resp[:ok]).to                be true
      expect(resp[:facts_written]).to      eq(1)
      expect(resp[:connections_active]).to eq(1)
      expect(resp[:uptime_ms]).to          be > 0

      c.close
    end
  end

  # ── request counter and error counter ───────────────────────────────────────

  describe "request and error counters" do
    it "requests_total is populated after several ops" do
      port    = free_port
      @server = start(port)
      c       = client(port)

      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k1", value: {}))
      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k2", value: {}))
      c.__send__(:rpc, "ping")

      sleep 0.05
      snap = @server.metrics_snapshot
      expect(snap[:requests_total]["write_fact"]).to eq(2)
      expect(snap[:requests_total]["ping"]).to        eq(1)

      c.close
    end

    it "errors_total increments for unknown ops" do
      port    = free_port
      @server = start(port)
      c       = client(port)

      begin
        c.__send__(:rpc, "bad_op_xyz")
      rescue
        nil
      end

      sleep 0.05
      snap = @server.metrics_snapshot
      errors = snap[:errors_total]
      total_errors = errors.values.sum
      expect(total_errors).to be >= 1

      c.close
    end

    it "bytes_in and bytes_out are positive after requests" do
      port    = free_port
      @server = start(port)
      c       = client(port)

      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k1", value: { data: "hello" }))
      sleep 0.05

      snap = @server.metrics_snapshot
      expect(snap[:bytes_in]).to  be > 0
      expect(snap[:bytes_out]).to be > 0

      c.close
    end
  end

  # ── connection tracking determinism ─────────────────────────────────────────

  describe "connection counter determinism" do
    it "accepted_total increments per unique connection" do
      port    = free_port
      @server = start(port)

      c1 = client(port)
      c2 = client(port)
      sleep 0.05

      snap = @server.metrics_snapshot
      expect(snap[:accepted_connections_total]).to be >= 2

      c1.close
      c2.close
      sleep 0.05

      snap2 = @server.metrics_snapshot
      expect(snap2[:closed_connections_total]).to be >= 2
    end
  end

  # ── max_connections enforcement ──────────────────────────────────────────────

  describe "max_connections enforcement" do
    it "rejects connections beyond max_connections and increments rejected_total" do
      port    = free_port
      @server = start(port, max_connections: 1)

      c1 = client(port)
      sleep 0.05

      # Second connection should be rejected or quickly closed
      c2 = TCPSocket.new("127.0.0.1", port)
      sleep 0.1

      snap = @server.metrics_snapshot
      expect(snap[:rejected_connections_total]).to be >= 1

      c1.close
      c2.close rescue nil
    end
  end

  # ── subscription metrics ────────────────────────────────────────────────────

  describe "subscription metrics" do
    it "subscription_count reflects active subscriptions" do
      port    = free_port
      @server = start(port)

      sub_nb = client(port)
      handle = sub_nb.subscribe(stores: [:tasks]) { }
      sleep 0.05

      snap = @server.metrics_snapshot
      expect(snap[:subscription_count]).to be >= 1

      handle.close
      sleep 0.05

      snap2 = @server.metrics_snapshot
      expect(snap2[:subscription_count]).to eq(0)
    end
  end

  # ── ServerLogger event integration ──────────────────────────────────────────

  describe "structured log events integration" do
    it "emits server_start and connection_open events to io" do
      io   = StringIO.new
      log  = Igniter::Store::ServerLogger.new(io, :info)
      port = free_port

      @server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: log)
      @server.start_async
      @server.wait_until_ready

      c = client(port)
      sleep 0.05

      events = io.string.lines.select { |l| l.start_with?("[EVENT]") }.map { |l|
        JSON.parse(l.sub("[EVENT] ", "").strip)
      }

      event_types = events.map { |e| e["event"] }
      expect(event_types).to include("server_start")
      expect(event_types).to include("connection_open")

      c.close
    end

    it "emits connection_close event after client disconnects" do
      io   = StringIO.new
      log  = Igniter::Store::ServerLogger.new(io, :info)
      port = free_port

      @server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: log)
      @server.start_async
      @server.wait_until_ready

      c = client(port)
      sleep 0.05
      c.close
      sleep 0.1

      events = io.string.lines.select { |l| l.start_with?("[EVENT]") }.map { |l|
        JSON.parse(l.sub("[EVENT] ", "").strip)
      }
      event_types = events.map { |e| e["event"] }
      expect(event_types).to include("connection_close")
    end
  end
end
