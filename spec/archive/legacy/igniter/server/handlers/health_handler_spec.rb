# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::Handlers::HealthHandler do
  let(:store)    { Igniter::Runtime::Stores::MemoryStore.new }
  let(:registry) { Igniter::Server::Registry.new }
  subject(:handler) { described_class.new(registry, store, node_url: "http://localhost:4567") }

  let(:contract_class) do
    Class.new(Igniter::Contract) do
      define { input :x; output :x }
    end
  end

  it "returns ok status with node info" do
    registry.register("MyContract", contract_class)
    result = handler.call(params: {}, body: {})
    data = JSON.parse(result[:body])
    expect(result[:status]).to eq(200)
    expect(data["status"]).to eq("ok")
    expect(data["node"]).to eq("http://localhost:4567")
    expect(data["contracts"]).to include("MyContract")
    expect(data["store"]).to eq("MemoryStore")
    expect(data["pending"]).to eq(0)
  end

  it "shows pending execution count" do
    # Manually save a pending snapshot
    store.save(
      { execution_id: "abc", states: { data: { status: "pending" } } },
      graph: "MyGraph"
    )
    result = handler.call(params: {}, body: {})
    data = JSON.parse(result[:body])
    expect(data["pending"]).to eq(1)
  end
end
