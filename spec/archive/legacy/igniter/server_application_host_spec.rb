# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-application/lib/igniter-application"
require_relative "../../packages/igniter-server/lib/igniter-server"

RSpec.describe Igniter::Server::ApplicationHost do
  let(:environment) do
    Igniter::Application.build_kernel
                        .host(:server, seam: described_class.new)
                        .set(:server, :host, value: "127.0.0.1")
                        .set(:server, :port, value: 5678)
                        .set(:server, :log_format, value: :json)
                        .set(:server, :drain_timeout, value: 15)
                        .register("HelloContract", Class.new(Igniter::Contract))
                        .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }
  end

  it "builds server config from application config and contract registry" do
    host = described_class.new
    projection = host.projection_for(environment: environment)
    config = host.build_config(environment: environment)

    expect(projection).to be_a(Igniter::Server::ApplicationConfigProjection)
    expect(projection.to_h).to include(host: "127.0.0.1", port: 5678)
    expect(config).to be_a(Igniter::Server::Config)
    expect(config.host).to eq("127.0.0.1")
    expect(config.port).to eq(5678)
    expect(config.log_format).to eq(:json)
    expect(config.drain_timeout).to eq(15)
    expect(config.registry.fetch("HelloContract")).to be_a(Class)
  end

  it "starts through the HTTP server with transport activation" do
    host = described_class.new
    config = host.build_config(environment: environment)
    fake_http_server = instance_double(Igniter::Server::HttpServer, start: :started)

    expect(Igniter::Server).to receive(:activate_remote_adapter!).ordered
    expect(Igniter::Server).to receive(:activate_agent_adapter!).ordered
    expect(Igniter::Server::HttpServer).to receive(:new).with(an_object_having_attributes(host: config.host, port: config.port)).and_return(fake_http_server)

    expect(host.start(environment: environment)).to eq(:started)
  end

  it "builds a rack app from the mapped server config" do
    host = described_class.new
    fake_rack_app = instance_double(Igniter::Server::RackApp)

    expect(Igniter::Server::RackApp).to receive(:new).with(an_object_having_attributes(host: "127.0.0.1", port: 5678)).and_return(fake_rack_app)

    expect(host.rack_app(environment: environment)).to eq(fake_rack_app)
  end
end
