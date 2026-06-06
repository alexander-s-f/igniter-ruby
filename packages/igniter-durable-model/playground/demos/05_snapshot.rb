# frozen_string_literal: true
# Demo 05 — WAL Snapshot Checkpoint
# Writes facts, takes a checkpoint, writes more facts, closes, then reopens.
# Demonstrates O(delta) startup instead of O(total_facts).
#
# NOTE: checkpoint is a no-op when the Rust native extension is loaded
# (NATIVE = true). The demo detects this and explains why.

require_relative "../setup"
require "tmpdir"

include Playground

def run_05(_ignored_store = nil)
  v    = Tools::Viewer
  task = Schema::Task

  v.header("05 · WAL Snapshot Checkpoint")

  if Igniter::Store::NATIVE
    puts "\n  ⚠  NATIVE = true: checkpoint is a no-op in this environment."
    puts "  The Rust FileBackend does not yet expose write_snapshot."
    puts "  Run without the compiled extension to try this demo."
    puts "  (candidate pressure documented in packages/igniter-ledger/README.md)"
    return
  end

  dir  = Dir.mktmpdir("igniter-playground")
  path = File.join(dir, "demo.wal")

  puts "\n▸ Session 1: write 5 pre-snapshot facts → checkpoint → write 3 more..."
  s1 = Playground.file_store(path)

  5.times { |i| s1.write(task, key: "t#{i}", title: "Pre-snapshot #{i}", status: :open) }
  puts "  Facts before checkpoint: #{s1.instance_variable_get(:@inner).fact_count}"

  Playground.inner_store(s1).checkpoint
  snap = path + Igniter::Store::FileBackend::SNAPSHOT_SUFFIX
  puts "  Snapshot written: #{File.basename(snap)} (#{File.size(snap)} bytes)"

  3.times { |i| s1.write(task, key: "d#{i}", title: "Post-checkpoint #{i}", status: :open) }
  puts "  Facts after 3 more writes: #{Playground.inner_store(s1).fact_count}"
  s1.close

  puts "\n▸ Session 2: reopen — replays snapshot + WAL delta only..."
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  s2 = Playground.file_store(path)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000).round(3)

  puts "  Reopened in #{elapsed}ms  |  Total facts loaded: #{Playground.inner_store(s2).fact_count}"

  all = s2.scope(task, :open)
  v.records(all, task, title: "All tasks after reopen (#{all.size})")
  s2.close
ensure
  FileUtils.rm_rf(dir) if dir
end

run_05 if __FILE__ == $PROGRAM_NAME
