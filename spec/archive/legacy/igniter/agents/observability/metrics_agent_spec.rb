# frozen_string_literal: true

require "spec_helper"
require "igniter/agents"

RSpec.describe Igniter::Agents::MetricsAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  describe "on :increment" do
    it "creates a counter with the given name" do
      result = call_handler(:increment, payload: { name: "requests" })
      expect(result[:counters]).to have_key("requests")
    end

    it "defaults :by to 1.0" do
      result = call_handler(:increment, payload: { name: "x" })
      expect(result[:counters]["x"]).to eq(1.0)
    end

    it "accumulates increments" do
      state  = call_handler(:increment, payload: { name: "x", by: 3 })
      result = call_handler(:increment, state: state, payload: { name: "x", by: 7 })
      expect(result[:counters]["x"]).to eq(10.0)
    end

    it "coerces name to string" do
      result = call_handler(:increment, payload: { name: :requests })
      expect(result[:counters]).to have_key("requests")
    end
  end

  describe "on :gauge" do
    it "sets the gauge value" do
      result = call_handler(:gauge, payload: { name: "queue_depth", value: 42 })
      expect(result[:gauges]["queue_depth"]).to eq(42.0)
    end

    it "overwrites previous value" do
      state  = call_handler(:gauge, payload: { name: "g", value: 5 })
      result = call_handler(:gauge, state: state, payload: { name: "g", value: 99 })
      expect(result[:gauges]["g"]).to eq(99.0)
    end
  end

  describe "on :observe" do
    it "records count, sum, min, max" do
      state  = call_handler(:observe, payload: { name: "latency", value: 0.1 })
      result = call_handler(:observe, state: state, payload: { name: "latency", value: 0.3 })
      bucket = result[:histograms]["latency"]
      expect(bucket[:count]).to eq(2)
      expect(bucket[:sum]).to be_within(0.001).of(0.4)
      expect(bucket[:min]).to be_within(0.001).of(0.1)
      expect(bucket[:max]).to be_within(0.001).of(0.3)
    end

    it "appends individual values" do
      state  = call_handler(:observe, payload: { name: "rt", value: 1.0 })
      result = call_handler(:observe, state: state, payload: { name: "rt", value: 2.0 })
      expect(result[:histograms]["rt"][:values]).to eq([1.0, 2.0])
    end
  end

  describe "on :snapshot" do
    it "returns a Snapshot struct" do
      state  = call_handler(:increment, payload: { name: "c", by: 5 })
      result = call_handler(:snapshot, state: state)
      expect(result).to be_a(described_class::Snapshot)
    end

    it "includes computed avg in histogram summary" do
      state  = call_handler(:observe, payload: { name: "rt", value: 2.0 })
      state  = call_handler(:observe, state: state, payload: { name: "rt", value: 4.0 })
      snap   = call_handler(:snapshot, state: state)
      expect(snap.histograms["rt"][:avg]).to eq(3.0)
    end

    it "returns copies so mutations don't affect stored state" do
      state      = call_handler(:increment, payload: { name: "c" })
      snap       = call_handler(:snapshot, state: state)
      snap.counters["c"] = 999.0
      result2 = call_handler(:snapshot, state: state)
      expect(result2.counters["c"]).to eq(1.0)
    end
  end

  describe "on :prometheus_text" do
    it "returns a String" do
      state  = call_handler(:increment, payload: { name: "req" })
      result = call_handler(:prometheus_text, state: state)
      expect(result).to be_a(String)
    end

    it "includes counter TYPE comment and value" do
      state  = call_handler(:increment, payload: { name: "req", by: 5 })
      text   = call_handler(:prometheus_text, state: state)
      expect(text).to include("# TYPE req counter")
      expect(text).to include("req 5.0")
    end

    it "includes gauge TYPE comment and value" do
      state = call_handler(:gauge, payload: { name: "depth", value: 7 })
      text  = call_handler(:prometheus_text, state: state)
      expect(text).to include("# TYPE depth gauge")
      expect(text).to include("depth 7.0")
    end

    it "includes histogram _count and _sum lines" do
      state = call_handler(:observe, payload: { name: "rt", value: 1.5 })
      text  = call_handler(:prometheus_text, state: state)
      expect(text).to include("rt_count 1")
      expect(text).to include("rt_sum 1.5")
    end
  end

  describe "on :reset" do
    it "clears all metric types" do
      state  = call_handler(:increment, payload: { name: "c" })
      state  = call_handler(:gauge, state: state, payload: { name: "g", value: 1 })
      result = call_handler(:reset, state: state)
      expect(result[:counters]).to be_empty
      expect(result[:gauges]).to be_empty
      expect(result[:histograms]).to be_empty
    end
  end

  describe ".render_prometheus" do
    it "is available as a class method" do
      state = { counters: { "x" => 2.0 }, gauges: {}, histograms: {} }
      text  = described_class.render_prometheus(state)
      expect(text).to include("x 2.0")
    end
  end
end
