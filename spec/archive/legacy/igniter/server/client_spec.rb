# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::Client do
  subject(:client) { described_class.new("http://node2:4568") }

  let(:success_body) do
    JSON.generate({
      "execution_id" => "uuid-123",
      "status" => "succeeded",
      "outputs" => { "result" => 42 }
    })
  end

  let(:pending_body) do
    JSON.generate({
      "execution_id" => "uuid-456",
      "status" => "pending",
      "waiting_for" => ["data_received"]
    })
  end

  let(:failure_body) do
    JSON.generate({
      "execution_id" => "uuid-789",
      "status" => "failed",
      "error" => { "type" => "ResolutionError", "message" => "Something went wrong", "node" => "compute_x" }
    })
  end

  def stub_http_response(body)
    http_response = instance_double(Net::HTTPOK, body: body)
    allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
  end

  context "when remote is not reachable" do
    before do
      allow_any_instance_of(Net::HTTP).to receive(:request)
        .and_raise(Errno::ECONNREFUSED, "connection refused")
    end

    it "raises ConnectionError on execute" do
      expect { client.execute("MyContract", inputs: { x: 1 }) }
        .to raise_error(Igniter::Server::Client::ConnectionError, /Cannot connect/)
    end

    it "raises ConnectionError on health check" do
      expect { client.health }
        .to raise_error(Igniter::Server::Client::ConnectionError, /Cannot connect/)
    end
  end

  context "with a successful response" do
    before { stub_http_response(success_body) }

    it "returns symbolized status and outputs" do
      result = client.execute("MyContract", inputs: { x: 1 })
      expect(result[:status]).to eq(:succeeded)
      expect(result[:execution_id]).to eq("uuid-123")
      expect(result[:outputs]).to eq({ result: 42 })
    end
  end

  context "with a pending response" do
    before { stub_http_response(pending_body) }

    it "returns pending status with waiting_for" do
      result = client.execute("MyContract", inputs: { x: 1 })
      expect(result[:status]).to eq(:pending)
      expect(result[:waiting_for]).to eq(["data_received"])
    end
  end

  context "with a failed response" do
    before { stub_http_response(failure_body) }

    it "returns failed status with error info" do
      result = client.execute("MyContract", inputs: { x: 1 })
      expect(result[:status]).to eq(:failed)
      expect(result[:error]["message"]).to eq("Something went wrong")
    end
  end

  context "with an HTTP error response" do
    before do
      http_response = instance_double(Net::HTTPNotFound, body: '{"error":"not found"}', code: "404")
      allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
    end

    it "raises RemoteError" do
      expect { client.execute("Missing", inputs: {}) }
        .to raise_error(Igniter::Server::Client::RemoteError, /Remote error 404/)
    end
  end

  describe "#deliver_event" do
    before { stub_http_response(success_body) }

    it "sends event delivery and returns response" do
      result = client.deliver_event("MyWorkflow",
                                    event: :data_received,
                                    correlation: { request_id: "r1" },
                                    payload: { data: "hello" })
      expect(result[:status]).to eq(:succeeded)
    end
  end
end
