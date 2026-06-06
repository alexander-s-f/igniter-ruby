# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk"
require "igniter/app"
require "igniter/server"
require "igniter/cluster"

RSpec.describe Igniter::SDK do
  before do
    described_class.reset!
  end

  describe ".capabilities" do
    it "registers built-in SDK capabilities with layer policies" do
      expect(described_class.fetch(:ai)).to have_attributes(
        entrypoint: "igniter/ai",
        allowed_layers: include(:app, :server, :cluster),
        provides_capabilities: include(:network, :external_api)
      )

      expect(described_class.fetch(:agents)).to have_attributes(
        entrypoint: "igniter/agents",
        allowed_layers: include(:app, :server, :cluster),
        provides_capabilities: eq([])
      )

      expect(described_class.fetch(:data)).to have_attributes(
        entrypoint: "igniter/sdk/data",
        allowed_layers: include(:core, :app, :server, :cluster),
        provides_capabilities: include(:database, :cache)
      )
    end

    it "filters capabilities by allowed layer" do
      names = described_class.capabilities(layer: :core).map(&:name)

      expect(names).to include(:data)
      expect(names).not_to include(:ai)
      expect(names).not_to include(:agents)
    end
  end

  describe ".activate!" do
    it "tracks successfully activated capabilities" do
      expect(described_class.activated?(:data)).to be(false)

      described_class.activate!(:data, layer: :core)

      expect(described_class.activated?(:data)).to be(true)
      expect(defined?(Igniter::Data)).to eq("constant")
      expect($LOADED_FEATURES.grep(/igniter\/sdk\/data\.rb$/)).not_to be_empty
    end

    it "activates the generic agents SDK pack for supported layers" do
      described_class.activate!(:agents, layer: :app)

      expect(described_class.activated?(:agents)).to be(true)
      expect(defined?(Igniter::Agents)).to eq("constant")
      expect($LOADED_FEATURES.grep(/igniter\/agents\.rb$/)).not_to be_empty
    end

    it "rejects capabilities that are forbidden for a layer" do
      expect {
        described_class.activate!(:ai, layer: :core)
      }.to raise_error(Igniter::SDK::LayerViolationError, /not allowed for layer :core/)
    end

    it "raises for unknown capabilities" do
      expect {
        described_class.activate!(:made_up, layer: :app)
      }.to raise_error(Igniter::SDK::UnknownCapabilityError, /Unknown SDK capability/)
    end
  end

  describe "layer helpers" do
    it "lets the top-level embedded layer declare SDK usage" do
      Igniter.use(:data)

      expect(Igniter.sdk_capabilities).to include(:data)
      expect(described_class.activated?(:data)).to be(true)
    end

    it "lets applications declare SDK capabilities without leaking between subclasses" do
      app_one = Class.new(Igniter::App)
      app_two = Class.new(Igniter::App)

      app_one.use(:tools, :agents)

      expect(app_one.sdk_capabilities).to include(:tools)
      expect(app_one.sdk_capabilities).to include(:agents)
      expect(app_two.sdk_capabilities).to eq([])
    end

    it "lets server and cluster layers declare SDK capabilities" do
      Igniter::Server.use(:channels)
      Igniter::Cluster.use(:ai)

      expect(Igniter::Server.sdk_capabilities).to include(:channels)
      expect(Igniter::Cluster.sdk_capabilities).to include(:ai)
    end
  end
end
