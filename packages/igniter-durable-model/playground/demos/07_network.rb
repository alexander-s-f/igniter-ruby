# frozen_string_literal: true
# Demo 07 — NetworkBackend / StoreServer
# Starts an in-process StoreServer on a free TCP port, connects two
# DurableModel::Store clients to it, and demonstrates that facts written
# by the first client are visible to the second after reconnect.
#
# This exercises the first step of the client-server projection model:
# the store is no longer in the app process — it lives in a separate
# server that multiple clients can share.
#
# NOTE: NetworkBackend/StoreServer require the pure-Ruby fallback
# (NATIVE = false). The demo detects this and explains why.

require_relative "../setup"
require "socket"

include Playground

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  p = s.addr[1]
  s.close
  p
end

def run_07(_store = nil)
  v    = Tools::Viewer
  task = Schema::Task

  v.header("07 · NetworkBackend / StoreServer")

  if Igniter::Store::NATIVE
    puts "\n  ⚠  NATIVE = true: NetworkBackend/StoreServer are pure-Ruby only."
    puts "  Rust-native wire deserialisation is planned for Phase 2."
    puts "  Run without the compiled extension to try this demo."
    return
  end

  port   = free_port
  server = Igniter::Store::StoreServer.new(
    address:   "127.0.0.1:#{port}",
    transport: :tcp,
    backend:   :memory
  )
  server.start_async
  sleep 0.05  # let the accept loop start

  puts "\n▸ Client 1: writing 4 tasks..."
  store1 = Igniter::DurableModel::Store.new(
    backend: :network, address: "127.0.0.1:#{port}", transport: :tcp
  )
  store1.register(task)
  store1.write(task, key: "t1", title: "Design API",  status: :open,  priority: :high)
  store1.write(task, key: "t2", title: "Write tests", status: :open,  priority: :normal)
  store1.write(task, key: "t3", title: "Ship it",     status: :open,  priority: :normal)
  store1.write(task, key: "t4", title: "Post-mortem", status: :done,  priority: :low)
  store1.close

  puts "▸ Client 2: reconnecting — reads from server state..."
  store2 = Igniter::DurableModel::Store.new(
    backend: :network, address: "127.0.0.1:#{port}", transport: :tcp
  )
  store2.register(task)

  all_open = store2.scope(task, :open)
  v.records(all_open, task, title: "Scope :open on client 2 (#{all_open.size})")

  puts "▸ Client 2: transitioning t1 to :done..."
  store2.write(task, key: "t1", title: "Design API", status: :done, priority: :high)

  after_open = store2.scope(task, :open)
  v.records(after_open, task, title: "Scope :open after transition (#{after_open.size})")

  puts "\n  ✓ Both clients shared the same server-side fact log."
  puts "  ✓ In-memory state was rebuilt from replay on reconnect."
  store2.close
  server.stop
end

run_07 if __FILE__ == $PROGRAM_NAME
