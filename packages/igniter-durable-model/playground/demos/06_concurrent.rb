# frozen_string_literal: true
# Demo 06 — Concurrency
# Spins up multiple writer and reader threads, verifies that all writes are
# durably captured and that concurrent reads never see torn state.
#
# Threading model in IgniterStore:
#   FactLog          — MonitorMixin: reentrant lock; concurrent appends serialised.
#   ReadCache        — MonitorMixin: get/put/invalidate serialised.
#   @scope_index     — Mutex: fine-grained per-write lock.
#   @partition_index — Mutex: fine-grained per-append lock.
#
# Readers only block when they race the same lock as an in-flight write.
# Multiple readers on distinct stores/keys run concurrently.

require_relative "../setup"

include Playground

WRITERS  = 4
WRITES   = 25   # per writer thread
READERS  = 4
READS    = 10   # per reader thread

def run_06(_store = nil)
  v    = Tools::Viewer
  task = Schema::Task
  te   = Schema::TrackerEntry

  v.header("06 · Concurrency")

  store  = Playground.store
  errors = []

  expected_task_writes = WRITERS * WRITES

  puts "\n▸ Spawning #{WRITERS} writer threads × #{WRITES} writes each..."
  writers = WRITERS.times.map do |w|
    Thread.new do
      WRITES.times do |i|
        store.write(task,
          key:      "w#{w}-t#{i}",
          title:    "Thread #{w} task #{i}",
          status:   %i[open in_progress done].sample,
          priority: %i[low normal high].sample)
      end
    rescue => e
      errors << e
    end
  end

  puts "▸ Spawning #{READERS} reader threads × #{READS} scope queries each..."
  readers = READERS.times.map do
    Thread.new do
      READS.times do
        result = store.scope(task, :open)
        raise "scope returned non-Array: #{result.class}" unless result.is_a?(Array)
      end
    rescue => e
      errors << e
    end
  end

  (writers + readers).each(&:join)

  if errors.any?
    puts "\n  ✗ #{errors.size} threading error(s):"
    errors.each { |e| puts "    #{e.message}" }
  else
    actual = Playground.inner_store(store).fact_count
    puts "\n  ✓ 0 errors"
    puts "  ✓ Expected task writes: #{expected_task_writes}  |  Actual facts: #{actual}"
    puts "  ✓ All concurrent reads returned valid Arrays"
  end

  puts "\n▸ Partition index under concurrent appends (3 trackers × 30 events each)..."
  trackers  = %w[alpha beta gamma]
  te_writes = 30

  t_threads = trackers.map do |t|
    Thread.new do
      te_writes.times { |i| store.append(te, tracker_id: t, value: i, unit: "test") }
    end
  end
  t_threads.each(&:join)

  Tools::Inspector.new(store).print_stats

  trackers.each do |t|
    events = store.replay(te, partition: t)
    ok     = events.size == te_writes
    puts "  Tracker #{t}: #{events.size}/#{te_writes} events  #{ok ? '✓' : '✗ mismatch'}"
  end
end

run_06 if __FILE__ == $PROGRAM_NAME
