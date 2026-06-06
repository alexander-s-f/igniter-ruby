# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Runtime::RemoteAdapter do
  let(:adapter) { described_class.new }
  let(:node) do
    Igniter::Model::RemoteNode.new(
      id: "test:1",
      name: :remote_result,
      contract_name: "OtherContract",
      node_url: "http://localhost:4568",
      input_mapping: { raw: :data }
    )
  end

  it "raises a helpful error when no transport adapter is configured" do
    expect {
      adapter.call(node: node, inputs: { raw: "hello" })
    }.to raise_error(Igniter::ResolutionError, /activate_remote_adapter!|remote_adapter/)
  end

  it "can be injected through execution options without loading server" do
    custom_adapter = instance_double("CustomRemoteAdapter")

    contract_class = Class.new(Igniter::Contract) do
      runner :inline, remote_adapter: custom_adapter

      define do
        input :data
        remote :result,
               contract: "OtherContract",
               node: "http://unused.example",
               inputs: { raw: :data }
        output :result
      end
    end

    allow(custom_adapter).to receive(:call).and_return(
      status: :succeeded,
      outputs: { processed: "HELLO" }
    )

    contract = contract_class.new(data: "hello")
    contract.resolve_all

    expect(custom_adapter).to have_received(:call).with(
      hash_including(
        node: kind_of(Igniter::Model::RemoteNode),
        inputs: { raw: "hello" },
        execution: kind_of(Igniter::Runtime::Execution)
      )
    )
    expect(contract.result.result).to eq({ processed: "HELLO" })
  end
end
