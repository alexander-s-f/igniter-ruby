# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe "K8s probe endpoints via Router" do
  let(:store) { Igniter::Runtime::Stores::MemoryStore.new }
  let(:config) do
    cfg = Igniter::Server::Config.new
    cfg.store = store
    cfg
  end
  subject(:router) { Igniter::Server::Router.new(config) }

  let(:simple_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :x
        compute :y, depends_on: :x, call: ->(x:) { x + 1 }
        output :y
      end
    end
  end

  describe "GET /v1/live" do
    it "returns 200 always" do
      result = router.call("GET", "/v1/live", "")
      expect(result[:status]).to eq(200)
    end

    it "includes status:alive and pid" do
      result = router.call("GET", "/v1/live", "")
      data   = JSON.parse(result[:body])
      expect(data["status"]).to eq("alive")
      expect(data["pid"]).to eq(Process.pid)
    end
  end

  describe "GET /v1/ready" do
    context "when no contracts are registered" do
      it "returns 503" do
        result = router.call("GET", "/v1/ready", "")
        expect(result[:status]).to eq(503)
      end

      it "reports no_contracts_registered" do
        result = router.call("GET", "/v1/ready", "")
        data   = JSON.parse(result[:body])
        expect(data["checks"]["contracts"]).to eq("no_contracts_registered")
      end
    end

    context "when a contract is registered and store is accessible" do
      before { config.register("MyContract", simple_contract) }

      it "returns 200" do
        result = router.call("GET", "/v1/ready", "")
        expect(result[:status]).to eq(200)
      end

      it "reports all checks ok" do
        result = router.call("GET", "/v1/ready", "")
        data   = JSON.parse(result[:body])
        expect(data["status"]).to eq("ready")
        expect(data["checks"].values).to all(eq("ok"))
      end
    end
  end

  describe "GET /v1/metrics" do
    context "without a metrics_collector configured" do
      it "returns 501" do
        result = router.call("GET", "/v1/metrics", "")
        expect(result[:status]).to eq(501)
      end
    end

    context "with a metrics_collector configured" do
      before { config.metrics_collector = Igniter::Metrics::Collector.new }

      it "returns 200" do
        result = router.call("GET", "/v1/metrics", "")
        expect(result[:status]).to eq(200)
      end

      it "returns Prometheus text/plain content type" do
        result = router.call("GET", "/v1/metrics", "")
        expect(result[:headers]["Content-Type"]).to include("text/plain")
      end

      it "includes pending gauge in body" do
        config.register("MyContract", simple_contract)
        result = router.call("GET", "/v1/metrics", "")
        expect(result[:body]).to include("igniter_pending_executions")
      end
    end
  end
end

RSpec.describe Igniter::Server::ServerLogger do
  describe "text format" do
    it "outputs level and message" do
      out = StringIO.new
      logger = described_class.new(format: :text, out: out)
      logger.info("hello world")
      expect(out.string).to include("INFO")
      expect(out.string).to include("hello world")
    end

    it "appends key=value context pairs" do
      out = StringIO.new
      logger = described_class.new(format: :text, out: out)
      logger.warn("slow", duration: 1.5)
      expect(out.string).to include("duration=1.5")
    end
  end

  describe "json format" do
    it "outputs valid JSON with level, msg, time fields" do
      out = StringIO.new
      logger = described_class.new(format: :json, out: out)
      logger.error("boom", code: 500)

      parsed = JSON.parse(out.string.strip)
      expect(parsed["level"]).to eq("ERROR")
      expect(parsed["msg"]).to eq("boom")
      expect(parsed["time"]).to be_a(String)
      expect(parsed["code"]).to eq(500)
    end
  end

  it "falls back to direct output when mutex synchronization is unavailable" do
    out = StringIO.new
    logger = described_class.new(format: :text, out: out)
    mutex = instance_double(Mutex)

    logger.instance_variable_set(:@mutex, mutex)
    allow(mutex).to receive(:synchronize).and_raise(ThreadError, "can't be called from trap context")

    expect { logger.info("shutdown") }.not_to raise_error
    expect(out.string).to include("shutdown")
  end
end
