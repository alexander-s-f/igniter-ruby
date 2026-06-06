# frozen_string_literal: true

require "spec_helper"
require "igniter/core/metrics"

RSpec.describe Igniter::Metrics::Collector do
  subject(:collector) { described_class.new }

  describe "#call — execution lifecycle events" do
    let(:execution_id) { "exec-1" }

    def make_event(type, execution_id: "exec-1", payload: {}, timestamp: Time.now.utc) # rubocop:disable Metrics/MethodLength
      Igniter::Events::Event.new(
        event_id: "e1",
        type: type,
        execution_id: execution_id,
        node_id: nil,
        node_name: nil,
        path: nil,
        status: nil,
        payload: payload,
        timestamp: timestamp
      )
    end

    it "records execution_started + execution_finished as a counter increment" do
      t0 = Time.now.utc
      collector.call(make_event(:execution_started, payload: { graph: "MyGraph" }, timestamp: t0))
      collector.call(make_event(:execution_finished, payload: { graph: "MyGraph" }, timestamp: t0 + 0.05))

      snap = collector.snapshot
      key  = "igniter_executions_total{graph=\"MyGraph\",status=\"succeeded\"}"
      expect(snap.counters[key]).to eq(1)
    end

    it "records execution_failed as a failed counter" do
      t0 = Time.now.utc
      collector.call(make_event(:execution_started, payload: { graph: "G" }, timestamp: t0))
      collector.call(make_event(:execution_failed,  payload: { graph: "G" }, timestamp: t0 + 0.1))

      snap = collector.snapshot
      key  = "igniter_executions_total{graph=\"G\",status=\"failed\"}"
      expect(snap.counters[key]).to eq(1)
    end

    it "records duration histogram for execution" do
      t0 = Time.now.utc
      collector.call(make_event(:execution_started, payload: { graph: "G" }, timestamp: t0))
      collector.call(make_event(:execution_finished, payload: { graph: "G" }, timestamp: t0 + 0.01))

      snap = collector.snapshot
      entry = snap.histograms["igniter_execution_duration_seconds"]&.values&.first
      expect(entry).not_to be_nil
      expect(entry[:count]).to eq(1)
      expect(entry[:sum]).to be_within(0.001).of(0.01)
    end

    it "ignores unknown event types" do
      collector.call(make_event(:node_succeeded, payload: {}))
      snap = collector.snapshot
      expect(snap.counters).to be_empty
    end
  end

  describe "#record_http" do
    it "increments HTTP request counter" do
      collector.record_http(method: "GET", path: "/v1/live", status: 200, duration: 0.002)

      snap = collector.snapshot
      key  = "igniter_http_requests_total{method=\"GET\",path=\"/v1/live\",status=\"200\"}"
      expect(snap.counters[key]).to eq(1)
    end

    it "normalises dynamic path segments to avoid high cardinality" do
      collector.record_http(method: "POST",
                            path: "/v1/contracts/MyContract/execute",
                            status: 200,
                            duration: 0.01)

      snap = collector.snapshot
      key  = 'igniter_http_requests_total{method="POST",' \
             'path="/v1/contracts/:name/execute",status="200"}'
      expect(snap.counters[key]).to eq(1)
    end

    it "records HTTP duration histogram" do
      collector.record_http(method: "GET", path: "/v1/metrics", status: 200, duration: 0.003)

      snap  = collector.snapshot
      entry = snap.histograms["igniter_http_request_duration_seconds"]&.values&.first
      expect(entry).not_to be_nil
      expect(entry[:count]).to eq(1)
    end
  end

  describe "#snapshot" do
    it "returns frozen copies of internal state" do
      collector.record_http(method: "GET", path: "/v1/live", status: 200, duration: 0.001)
      snap = collector.snapshot
      expect(snap.counters).to be_frozen
      expect(snap.histograms).to be_frozen
    end

    it "does not reflect mutations after snapshot" do
      snap1 = collector.snapshot
      collector.record_http(method: "GET", path: "/v1/live", status: 200, duration: 0.001)
      snap2 = collector.snapshot
      expect(snap1.counters.size).to eq(0)
      expect(snap2.counters.size).to be > 0
    end
  end
end

RSpec.describe Igniter::Metrics::PrometheusExporter do
  let(:collector) { Igniter::Metrics::Collector.new }
  let(:store)     { Igniter::Runtime::Stores::MemoryStore.new }
  let(:registry)  { Igniter::Server::Registry.new }

  subject(:exporter) do
    described_class.new(collector, store: store, registry: registry)
  end

  before do
    require "igniter/server"
  end

  describe "#content_type" do
    it "returns Prometheus text format 0.0.4" do
      expect(exporter.content_type).to include("text/plain")
      expect(exporter.content_type).to include("0.0.4")
    end
  end

  describe "#export" do
    it "emits valid Prometheus text with HELP and TYPE lines for known metrics" do
      collector.record_http(method: "GET", path: "/v1/live", status: 200, duration: 0.001)
      output = exporter.export

      expect(output).to include("# HELP igniter_http_requests_total")
      expect(output).to include("# TYPE igniter_http_requests_total counter")
      expect(output).to include("igniter_http_requests_total{")
    end

    it "includes histogram bucket/sum/count lines" do
      collector.record_http(method: "GET", path: "/v1/live", status: 200, duration: 0.05)
      output = exporter.export

      expect(output).to include("igniter_http_request_duration_seconds_bucket{")
      expect(output).to include('le="+Inf"')
      expect(output).to include("igniter_http_request_duration_seconds_sum{")
      expect(output).to include("igniter_http_request_duration_seconds_count{")
    end

    it "includes pending gauge even with no executions" do
      contract_class = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :y, depends_on: :x, call: ->(x:) { x }
          output :y
        end
      end
      registry.register("TestContract", contract_class)

      output = exporter.export
      expect(output).to include("igniter_pending_executions{graph=\"TestContract\"}")
    end

    it "ends with a newline" do
      expect(exporter.export).to end_with("\n")
    end
  end
end
