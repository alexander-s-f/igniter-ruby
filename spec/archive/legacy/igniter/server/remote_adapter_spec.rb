# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::RemoteAdapter do
  let(:adapter) { described_class.new }

  it "supports static routing" do
    node = Igniter::Model::RemoteNode.new(
      id: "test:1",
      name: :remote_result,
      contract_name: "OtherContract",
      node_url: "http://localhost:4568",
      input_mapping: { raw: :data }
    )

    client = instance_double(Igniter::Server::Client)
    allow(Igniter::Server::Client).to receive(:new).with("http://localhost:4568", timeout: 30).and_return(client)
    allow(client).to receive(:execute).with("OtherContract", inputs: { raw: "hello" }).and_return(
      status: :succeeded,
      outputs: { processed: "HELLO" }
    )

    result = adapter.call(node: node, inputs: { raw: "hello" })
    expect(result[:outputs]).to eq({ processed: "HELLO" })
  end

  it "requires cluster for capability routing" do
    node = Igniter::Model::RemoteNode.new(
      id: "test:2",
      name: :remote_result,
      contract_name: "OtherContract",
      capability: :orders,
      input_mapping: { raw: :data }
    )

    expect {
      adapter.call(node: node, inputs: { raw: "hello" })
    }.to raise_error(Igniter::ResolutionError, /require 'igniter\/cluster'/)
  end

  it "requires cluster for capability query routing" do
    node = Igniter::Model::RemoteNode.new(
      id: "test:3",
      name: :remote_result,
      contract_name: "OtherContract",
      capability_query: { all_of: [:orders], tags: [:linux] },
      input_mapping: { raw: :data }
    )

    expect {
      adapter.call(node: node, inputs: { raw: "hello" })
    }.to raise_error(Igniter::ResolutionError, /require 'igniter\/cluster'/)
  end
end
