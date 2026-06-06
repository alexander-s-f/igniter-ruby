# frozen_string_literal: true
# Demo 08 — StoreServer Lifecycle
# Shows the full operational lifecycle of a StoreServer:
#   1. Configure via ServerConfig with captured log output
#   2. start_async + wait_until_ready (no sleep hack)
#   3. Two clients connect, write tasks, query stats
#   4. Show structured log output
#   5. Graceful stop with drain

require_relative "../setup"
require "socket"
require "stringio"

include Playground

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  p = s.addr[1]
  s.close
  p
end

def run_08(_store = nil)
  v    = Tools::Viewer
  task = Schema::Task

  v.header("08 · StoreServer Lifecycle")

  if Igniter::Store::NATIVE
    puts "\n  ⚠  NATIVE = true: StoreServer is pure-Ruby only in Phase 1."
    puts "  Run without the compiled extension to try this demo."
    return
  end

  # ── 1. Configure ────────────────────────────────────────────────────────────
  port   = free_port
  log_io = StringIO.new

  config = Igniter::Store::ServerConfig.new(
    host:          "127.0.0.1",
    port:          port,
    transport:     :tcp,
    backend:       :memory,
    log_io:        log_io,
    log_level:     :debug,
    drain_timeout: 2
  )

  puts "\n▸ ServerConfig:"
  config.to_h.each { |k, v| puts "    #{k.to_s.ljust(16)} #{v.inspect}" unless k == :log_io }

  # ── 2. Start ─────────────────────────────────────────────────────────────────
  puts "\n▸ Starting server..."
  server = Igniter::Store::StoreServer.new(config: config)
  server.start_async
  server.wait_until_ready
  puts "  ✓ Server ready on #{server.bind_address}"

  # ── 3. Two clients write + read ──────────────────────────────────────────────
  puts "\n▸ Client 1: writing 3 tasks..."
  store1 = Igniter::DurableModel::Store.new(
    backend: :network, address: "127.0.0.1:#{port}", transport: :tcp
  )
  store1.register(task)
  store1.write(task, key: "t1", title: "Design API",  status: :open,  priority: :high)
  store1.write(task, key: "t2", title: "Write tests", status: :open,  priority: :normal)
  store1.write(task, key: "t3", title: "Ship it",     status: :done,  priority: :low)

  puts "▸ Client 2: reconnecting + reading state..."
  store2 = Igniter::DurableModel::Store.new(
    backend: :network, address: "127.0.0.1:#{port}", transport: :tcp
  )
  store2.register(task)

  open_tasks = store2.scope(task, :open)
  v.records(open_tasks, task, title: "Scope :open on client 2 (#{open_tasks.size})")

  # ── 4. Stats ─────────────────────────────────────────────────────────────────
  puts "▸ Querying server stats..."
  # Access stats via the raw NetworkBackend through inner store
  nb1 = Playground.inner_store(store1).instance_variable_get(:@backend)
  nb2 = Playground.inner_store(store2).instance_variable_get(:@backend)
  stats = nb2.__send__(:rpc, "stats")

  puts "\n  Stats:"
  puts "    facts_written:      #{stats[:facts_written]}"
  puts "    connections_active: #{stats[:connections_active]}"
  puts "    uptime_ms:          #{stats[:uptime_ms]}"

  # ── 5. Close clients + graceful stop ─────────────────────────────────────────
  puts "\n▸ Closing clients and stopping server..."
  store1.close
  store2.close
  server.stop

  puts "  ✓ Server stopped."

  # ── 6. Print captured log ────────────────────────────────────────────────────
  puts "\n▸ Captured server log:"
  log_io.string.each_line { |l| puts "  #{l.chomp}" }
end

run_08 if __FILE__ == $PROGRAM_NAME
