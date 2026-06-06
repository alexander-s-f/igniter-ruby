# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/channels"

RSpec.describe Igniter::Channels::Webhook do
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  it "delivers JSON payloads and normalizes the response" do
    response = instance_double(Net::HTTPOK, body: '{"ok":true}', code: "200", to_hash: { "content-type" => ["application/json"] })
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(response).to receive(:[]).with("x-request-id").and_return("req-123")
    allow(response).to receive(:[]).with("x-correlation-id").and_return(nil)

    captured_request = nil
    allow(http).to receive(:request) do |request|
      captured_request = request
      response
    end

    result = described_class.new.deliver(
      to: "https://hooks.example.test/incoming",
      body: { event: "call.completed", score: 0.91 }
    )

    expect(captured_request).to be_a(Net::HTTP::Post)
    expect(captured_request.path).to eq("/incoming")
    expect(captured_request["Content-Type"]).to eq("application/json")
    expect(JSON.parse(captured_request.body)).to eq({ "event" => "call.completed", "score" => 0.91 })

    expect(result.status).to eq(:delivered)
    expect(result.provider).to eq(:webhook)
    expect(result.recipient).to eq("https://hooks.example.test/incoming")
    expect(result.external_id).to eq("req-123")
    expect(result.payload[:status_code]).to eq(200)
    expect(result.payload[:body]).to eq("ok" => true)
  end

  it "supports configured defaults, query params, headers, and basic auth" do
    response = instance_double(Net::HTTPAccepted, body: "", code: "202", to_hash: {})
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(response).to receive(:[]).with("x-request-id").and_return(nil)
    allow(response).to receive(:[]).with("x-correlation-id").and_return(nil)

    captured_request = nil
    allow(http).to receive(:request) do |request|
      captured_request = request
      response
    end

    webhook = described_class.new(
      url: "https://hooks.example.test/base",
      method: :put,
      headers: { "X-App" => "igniter" },
      params: { env: "test" },
      basic_auth: { username: "alice", password: "secret" }
    )

    result = webhook.deliver(
      body: "ping",
      metadata: { headers: { "X-Trace" => "trace-1" }, params: { attempt: 2 } }
    )

    expect(captured_request).to be_a(Net::HTTP::Put)
    expect(captured_request.path).to eq("/base?env=test&attempt=2")
    expect(captured_request["X-App"]).to eq("igniter")
    expect(captured_request["X-Trace"]).to eq("trace-1")
    expect(captured_request["authorization"]).to match(/^Basic /)
    expect(captured_request.body).to eq("ping")
    expect(result.status).to eq(:queued)
  end

  it "raises DeliveryError for non-success responses" do
    response = instance_double(Net::HTTPBadRequest, body: '{"error":"bad signature"}', code: "400", to_hash: {})
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)

    allow(http).to receive(:request).and_return(response)

    expect {
      described_class.new.deliver(to: "https://hooks.example.test/incoming", body: { ping: true })
    }.to raise_error(Igniter::Channels::DeliveryError, /HTTP 400/)
  end

  it "wraps connection errors as DeliveryError" do
    allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED, "connection refused")

    expect {
      described_class.new.deliver(to: "https://hooks.example.test/incoming", body: "ping")
    }.to raise_error(Igniter::Channels::DeliveryError, /Cannot deliver webhook/)
  end
end
