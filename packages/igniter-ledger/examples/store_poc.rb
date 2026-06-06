# frozen_string_literal: true

require "tmpdir"
require "igniter-ledger"

store = Igniter::Store.memory

invalidations = []
store.register_path(
  Igniter::Store.access_path(
    store: :reminders,
    lookup: :primary_key,
    scope: nil,
    filters: nil,
    cache_ttl: 60,
    consumers: [->(store_name, key) { invalidations << [store_name, key] }]
  )
)

t_before = Process.clock_gettime(Process::CLOCK_REALTIME)
first = store.write(store: :reminders, key: "r1", value: { title: "Buy milk", status: :open })
sleep 0.01
t_mid = Process.clock_gettime(Process::CLOCK_REALTIME)
second = store.write(store: :reminders, key: "r1", value: { title: "Buy milk", status: :closed })

store.append(history: :reminder_logs, event: { reminder_id: "r1", action: :created, at: t_before })
store.append(history: :reminder_logs, event: { reminder_id: "r1", action: :closed, at: Time.now.to_f })

wal_path = File.join(Dir.tmpdir, "igniter_ledger_package_poc_#{Process.pid}.jsonl")
begin
  file_store = Igniter::Store.open(wal_path)
  file_store.write(store: :tasks, key: "t1", value: { title: "Package POC", done: false })
  file_store.write(store: :tasks, key: "t1", value: { title: "Package POC", done: true })
  replayed = Igniter::Store.open(wal_path)

  puts "access_paths=#{store.schema_graph.paths_for(:reminders).length}"
  puts "chain_intact=#{second.causation == first.id}"
  puts "current_status=#{store.read(store: :reminders, key: "r1").fetch(:status)}"
  puts "status_at_mid=#{store.time_travel(store: :reminders, key: "r1", at: t_mid).fetch(:status)}"
  puts "invalidations=#{invalidations.inspect}"
  puts "history_count=#{store.history(store: :reminder_logs).length}"
  puts "wal_replay_done=#{replayed.read(store: :tasks, key: "t1").fetch(:done)}"
ensure
  File.delete(wal_path) if File.exist?(wal_path)
end
