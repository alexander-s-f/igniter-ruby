# frozen_string_literal: true
# Demo 02 — Time Travel
# Writes a record through several state transitions, captures timestamps,
# and reads back the historical state at each checkpoint.

require_relative "../setup"

include Playground

def run_02(store)
  v    = Tools::Viewer
  task = Schema::Task

  v.header("02 · Time Travel")

  store.write(task, key: "tx", title: "Time-travel task", status: :open)
  t_created = Process.clock_gettime(Process::CLOCK_REALTIME)
  sleep 0.02

  store.write(task, key: "tx", title: "Time-travel task", status: :in_progress)
  t_started = Process.clock_gettime(Process::CLOCK_REALTIME)
  sleep 0.02

  store.write(task, key: "tx", title: "Time-travel task", status: :done)

  puts "\n▸ Current state:"
  v.records([store.read(task, key: "tx")], task)

  puts "\n▸ At t_created (just after first write):"
  v.records([store.read(task, key: "tx", as_of: t_created)].compact, task)

  puts "\n▸ At t_started (just after second write):"
  v.records([store.read(task, key: "tx", as_of: t_started)].compact, task)

  puts "\n▸ Causation chain:"
  chain = store.causation_chain(task, key: "tx")
  v.chain(chain)
end

run_02(Playground.store) if __FILE__ == $PROGRAM_NAME
