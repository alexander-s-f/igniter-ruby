# frozen_string_literal: true

require "spec_helper"
require "igniter/app"

RSpec.describe "Igniter::App contracts-native application prototype" do
  let(:app_pack) do
    Module.new do
      def self.install_into_app_kernel(kernel)
        kernel.host(:cluster_app)
        kernel.provide(:notes_api, -> { ["n1", "n2"] })
      end
    end
  end

  it "builds a mutable app kernel with explicit runtime seams" do
    kernel = Igniter::App.build_kernel

    expect(kernel).to be_a(Igniter::App::Kernel)
    expect(kernel.host).to eq(:app)
    expect(kernel.loader).to eq(:filesystem)
    expect(kernel.scheduler).to eq(:threaded)
  end

  it "installs app-local packs and finalizes into a frozen profile" do
    profile = Igniter::App.build_kernel(app_pack)
                          .register("HelloContract", Class.new)
                          .contracts_path("contracts")
                          .schedule(:tick, every: "1h") {}
                          .finalize

    expect(profile).to be_a(Igniter::App::Profile)
    expect(profile.host_name).to eq(:cluster_app)
    expect(profile.supports_service?(:notes_api)).to be(true)
    expect(profile.service(:notes_api).call).to eq(["n1", "n2"])
    expect(profile.supports_contract?("HelloContract")).to be(true)
    expect(profile.app_pack_names).not_to be_empty
    expect(profile.path_groups).to eq([:contracts])
    expect(profile.scheduled_jobs.map { |job| job[:name] }).to eq([:tick])
    expect(profile.to_h).to include(
      host: :cluster_app,
      loader: :filesystem,
      scheduler: :threaded,
      services: [:notes_api],
      contracts: ["HelloContract"]
    )
  end

  it "builds an environment that compiles and executes contracts through igniter-contracts" do
    environment = Igniter::App.with(app_pack)

    result = environment.run(inputs: { name: "Alex" }) do
      input :name

      compute :message, depends_on: [:name] do |name:|
        "hello #{name}"
      end

      output :message
    end

    expect(result.outputs[:message]).to eq("hello Alex")
    expect(environment.service(:notes_api).call).to eq(["n1", "n2"])
  end

  it "materializes configured adapters from app registries" do
    environment = Igniter::App.build_kernel
                              .host(:cluster_app)
                              .loader(:filesystem)
                              .scheduler(:threaded)
                              .finalize
                              .then { |profile| Igniter::App::Environment.new(profile: profile) }

    expect(environment.host_adapter).to be_a(Igniter::App::ClusterAppHost)
    expect(environment.loader_adapter).to be_a(Igniter::App::FilesystemLoaderAdapter)
    expect(environment.scheduler_adapter).to be_a(Igniter::App::ThreadedSchedulerAdapter)
  end

  it "boots into a structured report with a serializable runtime snapshot" do
    environment = Igniter::App.build_kernel(app_pack)
                              .contracts_path("contracts")
                              .schedule(:tick, every: "1h") {}
                              .then { |kernel| Igniter::App::Environment.new(profile: kernel.finalize) }

    report = environment.boot(base_dir: Dir.pwd)

    expect(report).to be_a(Igniter::App::BootReport)
    expect(report.loaded_code?).to be(true)
    expect(report.scheduler_started?).to be(true)
    expect(environment.booted?).to be(true)
    expect(environment.snapshot).to be_a(Igniter::App::Snapshot)
    expect(environment.snapshot.to_h).to include(
      host: :cluster_app,
      loader: :filesystem,
      scheduler: :threaded,
      services: [:notes_api]
    )
    expect(environment.snapshot.to_h.fetch(:runtime)).to include(
      booted: true,
      code_loaded: true,
      scheduler_running: true
    )
  end
end
