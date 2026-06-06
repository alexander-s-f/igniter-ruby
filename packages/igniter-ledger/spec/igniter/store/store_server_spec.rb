# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"

RSpec.describe "StoreServer + ServerConfig + ServerLogger" do

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    p = s.addr[1]
    s.close
    p
  end

  def start(port, **opts)
    server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: null_logger, **opts)
    server.start_async
    server.wait_until_ready
    server
  end

  def null_logger
    Igniter::Store::ServerLogger.new(nil, :error)
  end

  def client(port)
    Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}")
  end

  after(:each) { @server&.stop }

  # ── ServerConfig ─────────────────────────────────────────────────────────────

  describe Igniter::Store::ServerConfig do
    it "applies all defaults correctly" do
      c = described_class.new
      expect(c.host).to          eq("127.0.0.1")
      expect(c.port).to          eq(7400)
      expect(c.transport).to     eq(:tcp)
      expect(c.backend).to       eq(:memory)
      expect(c.path).to          be_nil
      expect(c.log_level).to     eq(:info)
      expect(c.pid_file).to      be_nil
      expect(c.drain_timeout).to eq(5)
    end

    it "overrides individual fields" do
      c = described_class.new(host: "0.0.0.0", port: 9999, backend: :file, path: "/tmp/s.wal")
      expect(c.host).to    eq("0.0.0.0")
      expect(c.port).to    eq(9999)
      expect(c.backend).to eq(:file)
      expect(c.path).to    eq("/tmp/s.wal")
    end

    it "raises on unknown keys" do
      expect { described_class.new(unknown_key: 42) }.to raise_error(ArgumentError, /unknown/i)
    end

    it "#bind_address returns host:port for TCP" do
      c = described_class.new(host: "10.0.0.1", port: 8080)
      expect(c.bind_address).to eq("10.0.0.1:8080")
    end

    it "#to_h includes all fields" do
      h = described_class.new.to_h
      expect(h).to include(:host, :port, :transport, :backend, :drain_timeout)
    end
  end

  # ── ServerLogger ─────────────────────────────────────────────────────────────

  describe Igniter::Store::ServerLogger do
    it "writes timestamped lines to the IO" do
      io = StringIO.new
      log = described_class.new(io, :info)
      log.info("hello world")
      expect(io.string).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/)
      expect(io.string).to include("INFO")
      expect(io.string).to include("hello world")
    end

    it "suppresses messages below the configured level" do
      io = StringIO.new
      log = described_class.new(io, :warn)
      log.debug("ignored")
      log.info("also ignored")
      log.warn("visible")
      log.error("also visible")
      expect(io.string).not_to include("ignored")
      expect(io.string).to     include("visible")
      expect(io.string).to     include("also visible")
    end

    it "is silent when io is nil" do
      log = described_class.new(nil, :debug)
      expect { log.info("anything") }.not_to raise_error
    end

    it "is thread-safe (no interleaved lines under concurrent writes)" do
      io = StringIO.new
      log = described_class.new(io, :debug)
      threads = 10.times.map { |i| Thread.new { 20.times { log.info("msg #{i}") } } }
      threads.each(&:join)
      lines = io.string.split("\n")
      expect(lines.size).to eq(200)
      lines.each { |l| expect(l).to match(/^\[/) }
    end
  end

  # ── StoreServer lifecycle ────────────────────────────────────────────────────

  describe "ready latch" do
    it "wait_until_ready resolves immediately after initialize (socket bound on new)" do
      port = free_port
      @server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: null_logger)
      # Socket is already listening — no need to call start_async first
      expect { @server.wait_until_ready(timeout: 0.1) }.not_to raise_error
    end

    it "wait_until_ready resolves after start_async without sleep" do
      port = free_port
      @server = Igniter::Store::StoreServer.new(address: "127.0.0.1:#{port}", logger: null_logger)
      @server.start_async
      expect { @server.wait_until_ready(timeout: 2) }.not_to raise_error
    end
  end

  describe "#bind_address" do
    it "returns the correct host:port string" do
      port = free_port
      @server = start(port)
      expect(@server.bind_address).to eq("127.0.0.1:#{port}")
    end
  end

  describe "#active_connections" do
    it "counts connections while they are open and decrements after close" do
      port = free_port
      @server = start(port)

      c = client(port)
      # Give the server a moment to register the connection
      sleep 0.05
      expect(@server.active_connections).to eq(1)

      c.close
      sleep 0.05
      expect(@server.active_connections).to eq(0)
    end
  end

  describe "stats operation" do
    it "returns facts_written, connections_active, uptime_ms" do
      port = free_port
      @server = start(port)

      c = client(port)
      fact = Igniter::Store::Fact.build(store: :tasks, key: "t1", value: { n: 1 })
      c.write_fact(fact)

      resp = c.__send__(:rpc, "stats")
      expect(resp[:ok]).to                be true
      expect(resp[:facts_written]).to      eq(1)
      expect(resp[:connections_active]).to eq(1)
      expect(resp[:uptime_ms]).to          be > 0
      c.close
    end

    it "reports uptime_ms growing over time" do
      port = free_port
      @server = start(port)

      c1 = client(port)
      r1 = c1.__send__(:rpc, "stats")
      sleep 0.1
      r2 = c1.__send__(:rpc, "stats")
      expect(r2[:uptime_ms]).to be >= r1[:uptime_ms]
      c1.close
    end
  end

  describe "graceful stop / drain" do
    it "accepts no new connections after stop is called" do
      port = free_port
      @server = start(port)
      @server.stop

      expect { TCPSocket.new("127.0.0.1", port) }.to raise_error(Errno::ECONNREFUSED)
    end

    it "raises NetworkError for unknown ops" do
      port = free_port
      @server = start(port)
      c = client(port)
      expect { c.__send__(:rpc, "unknown_op") }
        .to raise_error(Igniter::Store::NetworkBackend::NetworkError, /unknown_op/)
      c.close
    end
  end

  describe "PID file" do
    it "writes PID on initialize and removes on stop" do
      pid_path = File.join(Dir.tmpdir, "igniter_store_#{rand(100_000)}.pid")
      port     = free_port
      @server  = Igniter::Store::StoreServer.new(
        address:  "127.0.0.1:#{port}",
        pid_file: pid_path,
        logger:   null_logger
      )

      expect(File.exist?(pid_path)).to be true
      expect(File.read(pid_path).strip).to eq(Process.pid.to_s)

      @server.stop

      expect(File.exist?(pid_path)).to be false
    ensure
      File.delete(pid_path) if File.exist?(pid_path.to_s)
    end
  end

  describe "ServerConfig integration" do
    it "constructs server from config object" do
      port = free_port
      io   = StringIO.new
      config = Igniter::Store::ServerConfig.new(
        host:      "127.0.0.1",
        port:      port,
        backend:   :memory,
        log_io:    io,
        log_level: :info
      )
      @server = Igniter::Store::StoreServer.new(config: config)
      @server.start_async
      @server.wait_until_ready

      c = client(port)
      c.write_fact(Igniter::Store::Fact.build(store: :x, key: "k1", value: { v: 1 }))
      c.close

      expect(io.string).to include("Listening on")
    end
  end

  describe "file-backed persistence with lifecycle" do
    it "persists facts and replays across server restart" do
      dir  = Dir.mktmpdir("store-server-spec")
      path = File.join(dir, "store.wal")
      port = free_port

      @server = start(port, backend: :file, path: path)
      c = client(port)
      3.times { |i| c.write_fact(Igniter::Store::Fact.build(store: :s, key: "k#{i}", value: { i: i })) }
      c.close
      @server.stop

      @server = start(port, backend: :file, path: path)
      c2 = client(port)
      facts = c2.replay
      c2.close

      expect(facts.size).to eq(3)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  describe "SubscriptionRegistry / push" do
    it "subscription_count reflects connected subscribers" do
      port    = free_port
      @server = start(port)

      sub = client(port)
      handle = sub.subscribe(stores: [:tasks]) { }
      sleep 0.05
      expect(@server.subscription_count(:tasks)).to eq(1)

      handle.close
      sleep 0.05
      expect(@server.subscription_count(:tasks)).to eq(0)
    end

    it "delivers fact_written events to a subscriber" do
      port    = free_port
      @server = start(port)

      received = []
      sub_nb   = client(port)
      handle   = sub_nb.subscribe(stores: [:tasks]) { |f| received << f }

      writer = client(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :tasks, key: "t1", value: { n: 1 }))
      sleep 0.05

      expect(received.size).to eq(1)
      expect(received.first.key).to eq("t1")

      handle.close
      writer.close
    end

    it "does not deliver facts for unsubscribed stores" do
      port    = free_port
      @server = start(port)

      received = []
      sub_nb   = client(port)
      handle   = sub_nb.subscribe(stores: [:reminders]) { |f| received << f }

      writer = client(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :tasks, key: "t1", value: {}))
      sleep 0.05

      expect(received).to be_empty

      handle.close
      writer.close
    end

    it "fan-out reaches multiple subscribers" do
      port    = free_port
      @server = start(port)

      buckets = Array.new(3) { [] }
      handles = buckets.map do |bucket|
        nb = client(port)
        nb.subscribe(stores: [:items]) { |f| bucket << f.key }
      end
      sleep 0.05

      writer = client(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :items, key: "x", value: {}))
      sleep 0.05

      buckets.each { |b| expect(b).to eq(["x"]) }

      handles.each(&:close)
      writer.close
    end
  end
end
