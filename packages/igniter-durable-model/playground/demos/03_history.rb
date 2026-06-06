# frozen_string_literal: true
# Demo 03 — History & Partition Replay
# Appends events to multiple tracker streams, then replays them
# by partition (O(partition slice) thanks to the materialized partition index).

require_relative "../setup"

include Playground

def run_03(store)
  v  = Tools::Viewer
  te = Schema::TrackerEntry

  v.header("03 · History & Partition Replay")

  puts "\n▸ Appending events for three trackers..."

  [
    ["sleep",  8.1,    "hours"],
    ["sleep",  7.5,    "hours"],
    ["mood",   7.0,    "score"],
    ["sleep",  6.8,    "hours"],
    ["steps",  9_500,  "count"],
    ["mood",   8.0,    "score"],
    ["steps",  11_200, "count"],
    ["sleep",  8.3,    "hours"]
  ].each do |tracker_id, value, unit|
    store.append(te, tracker_id: tracker_id, value: value, unit: unit)
  end

  all = store.replay(te)
  v.events(all, te, title: "All events (#{all.size})")

  %w[sleep mood steps].each do |t|
    events = store.replay(te, partition: t)
    v.events(events, te, title: "Tracker: #{t} (#{events.size} events)")
  end
end

run_03(Playground.store) if __FILE__ == $PROGRAM_NAME
