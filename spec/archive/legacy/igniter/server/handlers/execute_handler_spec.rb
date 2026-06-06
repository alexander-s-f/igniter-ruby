# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::Handlers::ExecuteHandler do
  let(:store)    { Igniter::Runtime::Stores::MemoryStore.new }
  let(:registry) { Igniter::Server::Registry.new }
  subject(:handler) { described_class.new(registry, store) }

  let(:simple_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :x
        compute :doubled, depends_on: :x, call: ->(x:) { x * 2 }
        output :doubled
      end
    end
  end

  let(:failing_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :x
        compute :result, depends_on: :x, call: ->(x:) { raise "boom" }
        output :result
      end
    end
  end

  before { registry.register("MyContract", simple_contract) }

  describe "successful execution" do
    it "returns succeeded status with outputs" do
      result = handler.call(params: { name: "MyContract" }, body: { "inputs" => { "x" => 5 } })
      data = JSON.parse(result[:body])
      expect(result[:status]).to eq(200)
      expect(data["status"]).to eq("succeeded")
      expect(data["outputs"]["doubled"]).to eq(10)
      expect(data["execution_id"]).to be_a(String)
    end
  end

  describe "unregistered contract" do
    it "returns 404" do
      result = handler.call(params: { name: "Unknown" }, body: { "inputs" => {} })
      expect(result[:status]).to eq(404)
      data = JSON.parse(result[:body])
      expect(data["error"]).to match(/not registered/)
    end
  end

  describe "failed execution" do
    before { registry.register("FailingContract", failing_contract) }

    it "returns failed status with error info" do
      result = handler.call(params: { name: "FailingContract" }, body: { "inputs" => { "x" => 1 } })
      data = JSON.parse(result[:body])
      expect(result[:status]).to eq(200)
      expect(data["status"]).to eq("failed")
      expect(data["error"]).to be_a(Hash)
    end
  end

  describe "distributed contract (with correlate_by)" do
    let(:distributed_contract) do
      Class.new(Igniter::Contract) do
        correlate_by :request_id

        define do
          input :request_id
          await :data, event: :data_received
          output :data
        end
      end
    end

    before { registry.register("DistributedContract", distributed_contract) }

    it "returns pending status with waiting_for" do
      result = handler.call(
        params: { name: "DistributedContract" },
        body:   { "inputs" => { "request_id" => "r1" } }
      )
      data = JSON.parse(result[:body])
      expect(result[:status]).to eq(200)
      expect(data["status"]).to eq("pending")
      expect(data["waiting_for"]).to include("data_received")
    end
  end
end
