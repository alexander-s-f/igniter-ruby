# frozen_string_literal: true
# Demo 01 — Write / Read / Scope
# Shows the fundamental store operations: write a record, read it back,
# query a scope, and watch the scope update after a state transition.

require_relative "../setup"

include Playground

def run_01(store)
  v    = Tools::Viewer
  task = Schema::Task

  v.header("01 · Write / Read / Scope")

  puts "\n▸ Writing tasks..."
  store.write(task, key: "t1", title: "Design API",  status: :open, priority: :high)
  store.write(task, key: "t2", title: "Write tests", status: :open)
  store.write(task, key: "t3", title: "Ship it",     status: :open)
  store.write(task, key: "t4", title: "Post-mortem", status: :done)

  puts "\n▸ Reading task t1..."
  t1 = store.read(task, key: "t1")
  v.records([t1], task, title: "Task t1")

  open_tasks = store.scope(task, :open)
  v.records(open_tasks, task, title: "Scope :open (#{open_tasks.size})")

  high_prio = store.scope(task, :high_priority)
  v.records(high_prio, task, title: "Scope :high_priority (#{high_prio.size})")

  puts "\n▸ Moving t1 to :done..."
  store.write(task, key: "t1", title: "Design API", status: :done, priority: :high)

  after_open = store.scope(task, :open)
  after_done = store.scope(task, :done)
  v.records(after_open, task, title: "Scope :open after transition (#{after_open.size})")
  v.records(after_done, task, title: "Scope :done after transition (#{after_done.size})")
end

run_01(Playground.store) if __FILE__ == $PROGRAM_NAME
