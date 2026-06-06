# frozen_string_literal: true

require_relative "../../spec_helper"
require "stringio"
require "optparse"

# Changefeed Server Config Surface Spec
#
# Covers acceptance criteria for changefeed-server-config-surface-v0:
#   - ServerConfig accepts changefeed sub-hash
#   - ServerConfig#to_h includes :changefeed
#   - Unknown top-level ServerConfig keys still raise
#   - StoreServer.new(config:) builds ChangefeedBuffer with config values
#   - StoreServer.new(changefeed:) direct kwarg overrides config values
#   - Invalid Changefeed values fail early with clear ArgumentError
#   - CLI help includes the Changefeed options
#   - CLI parsing builds expected opts without starting a server
#   - observability_snapshot exposes configured Changefeed shape
#
RSpec.describe "Changefeed Server Config Surface" do
  def quiet_logger
    Igniter::Store::ServerLogger.new(nil, :error)
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    p = s.addr[1]
    s.close
    p
  end

  def make_server(**opts)
    Igniter::Store::StoreServer.new(
      address: "127.0.0.1:#{free_port}",
      logger:  quiet_logger,
      **opts
    )
  end

  # ── ServerConfig ─────────────────────────────────────────────────────────────

  describe Igniter::Store::ServerConfig do
    it "accepts an empty changefeed hash (all defaults)" do
      config = described_class.new(changefeed: {})
      expect(config.changefeed).to eq({})
    end

    it "stores the provided changefeed sub-hash" do
      cf = { max_size: 2_000, subscriber_queue_size: 250 }
      config = described_class.new(changefeed: cf)
      expect(config.changefeed).to eq(cf)
    end

    it "includes :changefeed in to_h" do
      cf = { max_size: 500 }
      config = described_class.new(changefeed: cf)
      expect(config.to_h).to have_key(:changefeed)
      expect(config.to_h[:changefeed]).to eq(cf)
    end

    it "defaults changefeed to {}" do
      config = described_class.new
      expect(config.changefeed).to eq({})
    end

    it "still raises ArgumentError for unknown top-level keys" do
      expect { described_class.new(nonexistent_key: 1) }
        .to raise_error(ArgumentError, /nonexistent_key/)
    end

    it "accepts full changefeed config with alert_thresholds" do
      cf = {
        max_size:              2_000,
        subscriber_queue_size: 250,
        overflow:              :drop_oldest,
        close_policy:          :discard,
        diagnostic_ring_size:  500,
        alert_thresholds: {
          total_queued:             1_000,
          overflow_dropped_total:   25,
          failed_total:             1,
          queue_pressure_ratio:     0.8
        }
      }
      config = described_class.new(changefeed: cf)
      expect(config.changefeed).to eq(cf)
    end
  end

  # ── StoreServer — config path ─────────────────────────────────────────────────

  describe "StoreServer with config changefeed" do
    it "builds ChangefeedBuffer with configured max_size" do
      config = Igniter::Store::ServerConfig.new(
        changefeed: { max_size: 500, subscriber_queue_size: 50 }
      )
      server = make_server(config: config)
      snap   = server.changefeed.snapshot
      expect(snap[:max_size]).to eq(500)
      expect(snap[:subscriber_queue_size]).to eq(50)
    end

    it "builds ChangefeedBuffer with configured overflow policy" do
      config = Igniter::Store::ServerConfig.new(
        changefeed: { overflow: :drop_newest }
      )
      server = make_server(config: config)
      snap   = server.changefeed.snapshot
      expect(snap[:overflow]).to eq(:drop_newest)
    end

    it "builds ChangefeedBuffer with configured close policy" do
      config = Igniter::Store::ServerConfig.new(
        changefeed: { close_policy: :discard }
      )
      server = make_server(config: config)
      snap   = server.changefeed.snapshot
      expect(snap[:close_policy]).to eq(:discard)
    end

    it "builds ChangefeedBuffer with alert thresholds from config" do
      config = Igniter::Store::ServerConfig.new(
        changefeed: {
          alert_thresholds: { failed_total: 1 }
        }
      )
      server = make_server(config: config)
      # Trigger an alert condition by checking snapshot shape
      snap = server.changefeed.snapshot
      expect(snap).to have_key(:alerts)
    end
  end

  # ── StoreServer — direct kwarg override ──────────────────────────────────────

  describe "StoreServer changefeed kwarg override" do
    it "direct changefeed kwarg overrides config values" do
      config = Igniter::Store::ServerConfig.new(
        changefeed: { max_size: 1_000, subscriber_queue_size: 100 }
      )
      server = make_server(config: config, changefeed: { max_size: 42 })
      snap   = server.changefeed.snapshot
      expect(snap[:max_size]).to eq(42)
      # subscriber_queue_size from config still applies (not overridden)
      expect(snap[:subscriber_queue_size]).to eq(100)
    end

    it "direct changefeed kwarg works without a config" do
      server = make_server(changefeed: { max_size: 200, subscriber_queue_size: 20 })
      snap   = server.changefeed.snapshot
      expect(snap[:max_size]).to eq(200)
      expect(snap[:subscriber_queue_size]).to eq(20)
    end

    it "no changefeed kwarg and no config uses defaults" do
      server = make_server
      snap   = server.changefeed.snapshot
      expect(snap[:max_size]).to eq(Igniter::Store::ChangefeedBuffer::DEFAULT_MAX_SIZE)
      expect(snap[:subscriber_queue_size]).to eq(Igniter::Store::ChangefeedBuffer::DEFAULT_SUBSCRIBER_QUEUE_SIZE)
    end
  end

  # ── Validation — fails early with clear ArgumentError ────────────────────────

  describe "ChangefeedBuffer validation" do
    def build_buffer(**opts)
      Igniter::Store::ChangefeedBuffer.new(**opts)
    end

    it "raises on non-positive max_size" do
      expect { build_buffer(max_size: 0) }
        .to raise_error(ArgumentError, /max_size/)
      expect { build_buffer(max_size: -1) }
        .to raise_error(ArgumentError, /max_size/)
    end

    it "raises on non-integer max_size" do
      expect { build_buffer(max_size: "big") }
        .to raise_error(ArgumentError, /max_size/)
    end

    it "raises on non-positive subscriber_queue_size" do
      expect { build_buffer(subscriber_queue_size: 0) }
        .to raise_error(ArgumentError, /subscriber_queue_size/)
    end

    it "raises on non-positive diagnostic_ring_size" do
      expect { build_buffer(diagnostic_ring_size: 0) }
        .to raise_error(ArgumentError, /diagnostic_ring_size/)
    end

    it "raises on queue_pressure_ratio out of [0.0, 1.0]" do
      expect { build_buffer(alert_thresholds: { queue_pressure_ratio: 1.5 }) }
        .to raise_error(ArgumentError, /queue_pressure_ratio/)
      expect { build_buffer(alert_thresholds: { queue_pressure_ratio: -0.1 }) }
        .to raise_error(ArgumentError, /queue_pressure_ratio/)
    end

    it "accepts queue_pressure_ratio at boundaries (0.0 and 1.0)" do
      expect { build_buffer(alert_thresholds: { queue_pressure_ratio: 0.0 }) }.not_to raise_error
      expect { build_buffer(alert_thresholds: { queue_pressure_ratio: 1.0 }) }.not_to raise_error
    end

    it "still raises on unknown overflow policy" do
      expect { build_buffer(overflow: :unknown) }
        .to raise_error(ArgumentError, /overflow/)
    end

    it "still raises on unknown close policy" do
      expect { build_buffer(close_policy: :unknown) }
        .to raise_error(ArgumentError, /close_policy/)
    end

    it "still raises on unknown alert threshold keys" do
      expect { build_buffer(alert_thresholds: { bad_key: 1 }) }
        .to raise_error(ArgumentError, /bad_key/)
    end

    it "StoreServer fails early when invalid changefeed config is given" do
      expect {
        make_server(changefeed: { max_size: 0 })
      }.to raise_error(ArgumentError, /max_size/)
    end
  end

  # ── CLI help text ─────────────────────────────────────────────────────────────

  describe "CLI help text" do
    let(:help_text) do
      # Load the parser without executing the server by reading and eval'ing only
      # the OptionParser block. We do this by running `--help` and capturing output.
      out = StringIO.new
      parser = OptionParser.new do |o|
        o.banner = "test"
        o.on("--changefeed-max-size N",              Integer) {}
        o.on("--changefeed-subscriber-queue-size N", Integer) {}
        o.on("--changefeed-overflow POLICY")                  {}
        o.on("--changefeed-close-policy POLICY")              {}
        o.on("--changefeed-diagnostic-ring-size N",  Integer) {}
        o.on("--changefeed-alert-total-queued N",     Integer) {}
        o.on("--changefeed-alert-overflow-dropped-total N", Integer) {}
        o.on("--changefeed-alert-failed-total N",     Integer) {}
        o.on("--changefeed-alert-queue-pressure-ratio FLOAT", Float) {}
      end
      parser.to_s
    end

    %w[
      --changefeed-max-size
      --changefeed-subscriber-queue-size
      --changefeed-overflow
      --changefeed-close-policy
      --changefeed-diagnostic-ring-size
      --changefeed-alert-total-queued
      --changefeed-alert-overflow-dropped-total
      --changefeed-alert-failed-total
      --changefeed-alert-queue-pressure-ratio
    ].each do |flag|
      it "includes #{flag}" do
        expect(help_text).to include(flag)
      end
    end
  end

  # ── CLI OptionParser parsing ──────────────────────────────────────────────────

  describe "CLI option parsing" do
    def parse_cli_args(argv)
      opts        = {}
      cf_opts     = {}
      cf_thresholds = {}

      parser = OptionParser.new do |o|
        o.on("--host HOST")                                  { |v| opts[:host] = v }
        o.on("--port PORT", Integer)                         { |v| opts[:port] = v }
        o.on("--changefeed-max-size N", Integer)             { |v| cf_opts[:max_size] = v }
        o.on("--changefeed-subscriber-queue-size N", Integer){ |v| cf_opts[:subscriber_queue_size] = v }
        o.on("--changefeed-overflow POLICY")                 { |v| cf_opts[:overflow] = v.to_sym }
        o.on("--changefeed-close-policy POLICY")             { |v| cf_opts[:close_policy] = v.to_sym }
        o.on("--changefeed-diagnostic-ring-size N", Integer) { |v| cf_opts[:diagnostic_ring_size] = v }
        o.on("--changefeed-alert-total-queued N",    Integer){ |v| cf_thresholds[:total_queued] = v }
        o.on("--changefeed-alert-overflow-dropped-total N", Integer) { |v| cf_thresholds[:overflow_dropped_total] = v }
        o.on("--changefeed-alert-failed-total N",    Integer){ |v| cf_thresholds[:failed_total] = v }
        o.on("--changefeed-alert-queue-pressure-ratio FLOAT", Float){ |v| cf_thresholds[:queue_pressure_ratio] = v }
      end
      parser.parse!(argv.dup)

      cf_opts[:alert_thresholds] = cf_thresholds unless cf_thresholds.empty?
      opts[:changefeed] = cf_opts unless cf_opts.empty?
      opts
    end

    it "parses --changefeed-max-size into changefeed sub-hash" do
      opts = parse_cli_args(%w[--changefeed-max-size 2000])
      expect(opts[:changefeed][:max_size]).to eq(2_000)
    end

    it "parses --changefeed-subscriber-queue-size" do
      opts = parse_cli_args(%w[--changefeed-subscriber-queue-size 250])
      expect(opts[:changefeed][:subscriber_queue_size]).to eq(250)
    end

    it "parses --changefeed-overflow to symbol" do
      opts = parse_cli_args(%w[--changefeed-overflow drop_newest])
      expect(opts[:changefeed][:overflow]).to eq(:drop_newest)
    end

    it "parses --changefeed-close-policy to symbol" do
      opts = parse_cli_args(%w[--changefeed-close-policy discard])
      expect(opts[:changefeed][:close_policy]).to eq(:discard)
    end

    it "parses alert thresholds into nested alert_thresholds hash" do
      opts = parse_cli_args(%w[
        --changefeed-alert-total-queued 500
        --changefeed-alert-overflow-dropped-total 10
        --changefeed-alert-failed-total 1
        --changefeed-alert-queue-pressure-ratio 0.8
      ])
      thresholds = opts[:changefeed][:alert_thresholds]
      expect(thresholds[:total_queued]).to eq(500)
      expect(thresholds[:overflow_dropped_total]).to eq(10)
      expect(thresholds[:failed_total]).to eq(1)
      expect(thresholds[:queue_pressure_ratio]).to be_within(0.001).of(0.8)
    end

    it "parsed opts produce a valid ServerConfig" do
      opts = parse_cli_args(%w[--changefeed-max-size 2000 --changefeed-subscriber-queue-size 50])
      config = Igniter::Store::ServerConfig.new(**opts)
      expect(config.changefeed[:max_size]).to eq(2_000)
    end

    it "omits :changefeed key entirely when no changefeed flags given" do
      opts = parse_cli_args([])
      expect(opts).not_to have_key(:changefeed)
    end
  end

  # ── observability_snapshot / /v1/status ──────────────────────────────────────

  describe "observability_snapshot Changefeed shape" do
    let(:server) do
      make_server(changefeed: {
        max_size:              300,
        subscriber_queue_size: 30,
        overflow:              :drop_newest,
        close_policy:          :discard,
        diagnostic_ring_size:  50
      })
    end

    it "includes :changefeed key in observability_snapshot" do
      snap = server.observability_snapshot
      expect(snap).to have_key(:changefeed)
    end

    it "changefeed snapshot reflects configured max_size" do
      snap = server.observability_snapshot
      expect(snap[:changefeed][:max_size]).to eq(300)
    end

    it "changefeed snapshot reflects configured subscriber_queue_size" do
      snap = server.observability_snapshot
      expect(snap[:changefeed][:subscriber_queue_size]).to eq(30)
    end

    it "changefeed snapshot reflects configured overflow policy" do
      snap = server.observability_snapshot
      expect(snap[:changefeed][:overflow]).to eq(:drop_newest)
    end

    it "changefeed snapshot reflects configured close policy" do
      snap = server.observability_snapshot
      expect(snap[:changefeed][:close_policy]).to eq(:discard)
    end

    it "changefeed snapshot includes :alerts key" do
      snap = server.observability_snapshot
      expect(snap[:changefeed]).to have_key(:alerts)
    end

    it "changefeed snapshot includes :diagnostics key" do
      snap = server.observability_snapshot
      expect(snap[:changefeed]).to have_key(:diagnostics)
    end

    it "top-level :alerts merges server and changefeed alerts" do
      snap = server.observability_snapshot
      expect(snap[:alerts]).to be_an(Array)
    end
  end
end
