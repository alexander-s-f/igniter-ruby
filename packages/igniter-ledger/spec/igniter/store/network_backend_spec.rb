# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "NetworkBackend + StoreServer" do
  # Finds a free TCP port by binding briefly with port 0, then releasing it.
  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def null_logger
    Igniter::Store::ServerLogger.new(nil, :error)
  end

  def start_server(port, backend: :memory, path: nil)
    server = Igniter::Store::StoreServer.new(
      address:  "127.0.0.1:#{port}",
      transport: :tcp,
      backend:  backend,
      path:     path,
      logger:   null_logger
    )
    server.start_async
    server.wait_until_ready
    [server, nil]
  end

  def client_backend(port)
    Igniter::Store::NetworkBackend.new(address: "127.0.0.1:#{port}", transport: :tcp)
  end

  after(:each) { @server&.stop }

  describe "basic write / replay" do
    it "stores facts durably and replays them to a second client" do
      port = free_port
      @server, = start_server(port)

      c1 = client_backend(port)
      fact = Igniter::Store::Fact.build(
        store: :tasks, key: "t1", value: { title: "Hello", status: :open }
      )
      c1.write_fact(fact)
      c1.close

      c2 = client_backend(port)
      replayed = c2.replay
      c2.close

      expect(replayed.size).to eq(1)
      expect(replayed.first.key).to eq("t1")
      expect(replayed.first.value).to include(title: "Hello")
    end

    it "replays multiple facts in insertion order (by timestamp)" do
      port = free_port
      @server, = start_server(port)

      c = client_backend(port)
      3.times do |i|
        c.write_fact(Igniter::Store::Fact.build(
          store: :items, key: "k#{i}", value: { n: i }
        ))
      end
      facts = c.replay
      c.close

      expect(facts.size).to eq(3)
      # timestamps must be non-decreasing
      times = facts.map(&:transaction_time)
      expect(times).to eq(times.sort)
    end
  end

  describe "IgniterStore integration via NetworkBackend" do
    it "supports full write/read/scope cycle over the network" do
      port = free_port
      @server, = start_server(port)

      nb    = client_backend(port)
      store = Igniter::Store::IgniterStore.new(backend: nb)
      # Replay initial state (empty for a fresh server)
      nb.replay.each { |f| store.__send__(:replay, f) }

      store.register_path(
        Igniter::Store::AccessPath.new(
          store: :tasks, scope: :open, filters: { status: :open }
        )
      )

      store.write(store: :tasks, key: "t1", value: { status: :open, title: "Work" })
      store.write(store: :tasks, key: "t2", value: { status: :done, title: "Done" })

      open_facts = store.query(store: :tasks, scope: :open)
      expect(open_facts.map { |f| f.value[:title] }).to eq(["Work"])

      nb.close
    end

    it "second client reconnects and rebuilds in-memory state from replay" do
      port = free_port
      @server, = start_server(port)

      # First client writes two facts
      nb1    = client_backend(port)
      store1 = Igniter::Store::IgniterStore.new(backend: nb1)
      nb1.replay.each { |f| store1.__send__(:replay, f) }
      store1.write(store: :tasks, key: "a", value: { status: :open })
      store1.write(store: :tasks, key: "b", value: { status: :open })
      nb1.close

      # Second client connects fresh — must see both facts
      nb2    = client_backend(port)
      store2 = Igniter::Store::IgniterStore.new(backend: nb2)
      nb2.replay.each { |f| store2.__send__(:replay, f) }

      expect(store2.fact_count).to eq(2)
      # JSON serialization converts symbol values to strings over the wire
      expect(store2.read(store: :tasks, key: "a")).to include(status: "open")
      nb2.close
    end
  end

  describe "ping / unknown op" do
    it "responds to ping with pong" do
      port = free_port
      @server, = start_server(port)

      nb = client_backend(port)
      # Access private rpc for direct protocol test
      response = nb.__send__(:rpc, "ping")
      expect(response[:ok]).to be true
      expect(response[:pong]).to be true
      nb.close
    end
  end

  describe "write_snapshot passthrough" do
    it "forwards write_snapshot to server (memory backend silently accepts)" do
      port = free_port
      @server, = start_server(port)

      nb = client_backend(port)
      fact = Igniter::Store::Fact.build(
        store: :tasks, key: "snap1", value: { title: "Snapshot" }
      )
      nb.write_fact(fact)

      # write_snapshot should not raise even for memory backend
      expect { nb.write_snapshot([fact]) }.not_to raise_error
      nb.close
    end
  end

  describe "file-backed server" do
    it "persists facts across server restarts" do
      require "tmpdir"
      dir  = Dir.mktmpdir("igniter-network-spec")
      path = File.join(dir, "store.wal")

      port = free_port

      # Session 1: write 3 facts
      @server, = start_server(port, backend: :file, path: path)
      nb = client_backend(port)
      3.times do |i|
        nb.write_fact(Igniter::Store::Fact.build(
          store: :items, key: "k#{i}", value: { n: i }
        ))
      end
      nb.close
      @server.stop

      # Session 2: restart server with same WAL, replay
      @server, = start_server(port, backend: :file, path: path)
      nb2 = client_backend(port)
      facts = nb2.replay
      nb2.close

      expect(facts.size).to eq(3)
      keys = facts.map(&:key).sort
      expect(keys).to eq(%w[k0 k1 k2])
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "concurrent writes" do
    it "serialises concurrent write_fact calls without data loss" do
      port = free_port
      @server, = start_server(port)

      threads = 4.times.map do |t|
        Thread.new do
          nb = client_backend(port)
          5.times do |i|
            nb.write_fact(Igniter::Store::Fact.build(
              store: :items, key: "t#{t}-i#{i}", value: { thread: t, index: i }
            ))
          end
          nb.close
        end
      end
      threads.each(&:join)

      # One final client to count
      nb = client_backend(port)
      facts = nb.replay
      nb.close

      expect(facts.size).to eq(20)
    end
  end

  describe "subscribe / push" do
    it "delivers fact_written events to subscriber" do
      port = free_port
      @server, = start_server(port)

      received = []
      sub = client_backend(port)
      handle = sub.subscribe(stores: [:tasks]) { |f| received << f }

      writer = client_backend(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :tasks, key: "t1", value: { n: 1 }))
      sleep 0.05

      expect(received.size).to eq(1)
      expect(received.first.key).to eq("t1")
      expect(received.first.store).to eq(:tasks)

      handle.close
      writer.close
    end

    it "does not deliver facts for stores not subscribed to" do
      port = free_port
      @server, = start_server(port)

      received = []
      sub    = client_backend(port)
      handle = sub.subscribe(stores: [:reminders]) { |f| received << f }

      writer = client_backend(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :tasks, key: "t1", value: {}))
      sleep 0.05

      expect(received).to be_empty

      handle.close
      writer.close
    end

    it "one subscription covers multiple stores" do
      port = free_port
      @server, = start_server(port)

      received = []
      sub    = client_backend(port)
      handle = sub.subscribe(stores: [:tasks, :reminders]) { |f| received << f.store }

      writer = client_backend(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :tasks,     key: "t1", value: {}))
      writer.write_fact(Igniter::Store::Fact.build(store: :reminders, key: "r1", value: {}))
      writer.write_fact(Igniter::Store::Fact.build(store: :other,     key: "o1", value: {}))
      sleep 0.05

      expect(received.sort).to eq(%i[reminders tasks])

      handle.close
      writer.close
    end

    it "multiple subscribers each receive the fact" do
      port = free_port
      @server, = start_server(port)

      buckets = Array.new(3) { [] }
      handles = buckets.map do |bucket|
        nb = client_backend(port)
        nb.subscribe(stores: [:items]) { |f| bucket << f.key }
      end
      sleep 0.05

      writer = client_backend(port)
      writer.write_fact(Igniter::Store::Fact.build(store: :items, key: "x", value: {}))
      sleep 0.05

      buckets.each { |b| expect(b).to eq(["x"]) }

      handles.each(&:close)
      writer.close
    end

    it "subscription_count drops to zero after handle.close" do
      port = free_port
      @server, = start_server(port)

      sub    = client_backend(port)
      handle = sub.subscribe(stores: [:tasks]) { }
      sleep 0.05
      expect(@server.subscription_count(:tasks)).to eq(1)

      handle.close
      sleep 0.05
      expect(@server.subscription_count(:tasks)).to eq(0)
    end
  end
end
