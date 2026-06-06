# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-application/lib/igniter-application"

RSpec.describe "Igniter::Application clean contracts-native runtime" do
  class TestApplicationProvider < Igniter::Application::Provider
    attr_reader :boot_calls

    def initialize
      @boot_calls = []
    end

    def services(environment:)
      {
        analytics_api: -> { environment.config.fetch(:services, :analytics, :endpoint) }
      }
    end

    def interfaces(environment:)
      {
        public_analytics_api: Igniter::Application::Interface.new(
          name: :public_analytics_api,
          callable: -> { environment.config.fetch(:services, :analytics, :endpoint) },
          metadata: { audience: :external },
          source: :analytics
        )
      }
    end

    def boot(environment:)
      @boot_calls << environment.config.fetch(:runtime, :mode)
    end
  end

  class TestApplicationLoader
    attr_reader :loads

    def initialize
      @loads = []
    end

    def load!(base_dir:, paths:, environment:)
      @loads << {
        base_dir: base_dir.to_s,
        paths: paths
      }
      self
    end
  end

  class TestApplicationScheduler
    attr_reader :starts, :stops

    def initialize
      @starts = []
      @stops = 0
    end

    def start(environment:)
      @starts << environment.profile.scheduler_name
      self
    end

    def stop(environment:)
      @stops += 1
      self
    end
  end

  class TestApplicationHost
    attr_reader :activations, :starts, :racks

    def initialize
      @activations = 0
      @starts = 0
      @racks = 0
    end

    def activate!(environment:)
      @activations += 1
      self
    end

    def start(environment:)
      @starts += 1
      :started
    end

    def rack_app(environment:)
      @racks += 1
      :rack_app
    end
  end

  let(:application_pack) do
    Module.new do
      def self.install_into_application_kernel(kernel)
        kernel.provide(:notes_api, -> { ["n1", "n2"] })
        kernel.expose(:public_notes_api, -> { ["n1", "n2"] }, metadata: { audience: :external })
      end
    end
  end

  it "builds a mutable kernel with clean defaults" do
    kernel = Igniter::Application.build_kernel

    expect(kernel).to be_a(Igniter::Application::Kernel)
    expect(kernel.host).to eq(:embedded)
    expect(kernel.loader).to eq(:manual)
    expect(kernel.scheduler).to eq(:manual)
  end

  it "installs application packs and finalizes into a frozen profile" do
    provider = TestApplicationProvider.new

    profile = Igniter::Application.build_kernel(application_pack)
                                  .register_provider(:analytics, provider)
                                  .configure(
                                    runtime: { mode: :test },
                                    services: { analytics: { endpoint: "memory://analytics" } }
                                  )
                                  .register("HelloContract", Class.new)
                                  .contracts_path("contracts")
                                  .schedule(:tick, every: "1h") {}
                                  .finalize

    expect(profile).to be_a(Igniter::Application::Profile)
    expect(profile.supports_service?(:notes_api)).to be(true)
    expect(profile.service(:notes_api).call).to eq(["n1", "n2"])
    expect(profile.supports_contract?("HelloContract")).to be(true)
    expect(profile.service_registry).to be_a(Igniter::Application::ServiceRegistry)
    expect(profile.contract_registry).to be_a(Igniter::Application::ContractRegistry)
    expect(profile.application_pack_names).not_to be_empty
    expect(profile.provider_names).to eq([:analytics])
    expect(profile.interface_names).to eq([:public_notes_api])
    expect(profile.path_groups).to eq([:contracts])
    expect(profile.scheduled_job_names).to eq([:tick])
    expect(profile.config.fetch(:runtime, :mode)).to eq(:test)
    expect(profile.to_h).to include(
      host: :embedded,
      loader: :manual,
      scheduler: :manual,
      interfaces: [:public_notes_api],
      contracts: ["HelloContract"]
    )
    expect(profile.to_h.fetch(:services)).to include(:notes_api, :public_notes_api)
    expect(profile.to_h.fetch(:config)).to include(runtime: { mode: :test })
    expect(profile.interface_definition(:public_notes_api).metadata).to include(audience: :external)
    expect(profile.contract_registry.names).to eq(["HelloContract"])
  end

  it "executes contracts through igniter-contracts without touching legacy app runtime" do
    environment = Igniter::Application.with(application_pack)

    result = environment.run(inputs: { name: "Alex" }) do
      input :name

      compute :message, depends_on: [:name] do |name:|
        "hello #{name}"
      end

      output :message
    end

    expect(result.outputs[:message]).to eq("hello Alex")
    expect(environment.service(:notes_api).call).to eq(["n1", "n2"])
    expect(environment.interface(:public_notes_api).call).to eq(["n1", "n2"])
  end

  it "boots through explicit seams and exposes a structured runtime snapshot" do
    loader = TestApplicationLoader.new
    scheduler = TestApplicationScheduler.new
    host = TestApplicationHost.new
    provider = TestApplicationProvider.new

    environment = Igniter::Application.build_kernel(application_pack)
                                      .register_provider(:analytics, provider)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .loader(:filesystem, seam: loader)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .contracts_path("contracts")
                                      .schedule(:tick, every: "1h") {}
                                      .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

    report = environment.boot(base_dir: Dir.pwd, activate_transport: true)

    expect(report).to be_a(Igniter::Application::BootReport)
    expect(report.loaded_code?).to be(true)
    expect(report.providers_resolved?).to be(true)
    expect(report.scheduler_started?).to be(true)
    expect(report.transport_activated?).to be(true)
    expect(environment.booted?).to be(true)
    expect(environment.snapshot).to be_a(Igniter::Application::Snapshot)
    expect(environment.provider(:analytics)).to eq(provider)
    expect(environment.service(:analytics_api).call).to eq("memory://analytics")
    expect(environment.interface(:public_analytics_api).call).to eq("memory://analytics")
    expect(environment.interface_definition(:public_analytics_api).metadata).to include(audience: :external)
    expect(environment.service_definition(:analytics_api).source).to eq(:analytics)
    expect(loader.loads.first.fetch(:paths)).to include(contracts: ["contracts"])
    expect(scheduler.starts).to eq([:threaded])
    expect(provider.boot_calls).to eq([:test])
    expect(host.activations).to eq(1)
    expect(environment.start_host).to eq(:started)
    expect(environment.rack_app).to eq(:rack_app)
    expect(environment.snapshot.to_h).to include(
      host: :rack,
      loader: :filesystem,
      scheduler: :threaded
    )
    expect(environment.snapshot.to_h.fetch(:runtime)).to include(
      booted: true,
      code_loaded: true,
      providers_resolved: true,
      scheduler_running: true,
      transport_activated: true
    )
    expect(report.to_h.fetch(:phases)).to eq(
      [
        { name: :load_code, status: :completed },
        { name: :resolve_providers, status: :completed },
        { name: :start_scheduler, status: :completed },
        { name: :activate_transport, status: :completed }
      ]
    )
  end
end
