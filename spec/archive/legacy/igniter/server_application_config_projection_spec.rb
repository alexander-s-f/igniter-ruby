# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-application/lib/igniter-application"
require_relative "../../packages/igniter-server/lib/igniter-server"

RSpec.describe Igniter::Server::ApplicationConfigProjection do
  let(:contract_class) { Class.new(Igniter::Contract) }
  let(:environment) do
    Igniter::Application.build_kernel
                        .set(:server, :host, value: "127.0.0.1")
                        .set(:server, :port, value: 5678)
                        .set(:server, :log_format, value: :json)
                        .set(:server, :drain_timeout, value: 15)
                        .register("HelloContract", contract_class)
                        .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }
  end

  it "projects application config into a typed server-facing value object" do
    projection = described_class.from_environment(environment)

    expect(projection.host).to eq("127.0.0.1")
    expect(projection.port).to eq(5678)
    expect(projection.log_format).to eq(:json)
    expect(projection.drain_timeout).to eq(15)
    expect(projection.contracts).to include("HelloContract" => contract_class)
    expect(projection.to_h).to include(
      host: "127.0.0.1",
      port: 5678,
      log_format: :json,
      drain_timeout: 15,
      contracts: ["HelloContract"]
    )
  end

  it "materializes an igniter-server config from the projection" do
    config = described_class.from_environment(environment).to_server_config

    expect(config).to be_a(Igniter::Server::Config)
    expect(config.host).to eq("127.0.0.1")
    expect(config.port).to eq(5678)
    expect(config.registry.fetch("HelloContract")).to eq(contract_class)
  end
end
