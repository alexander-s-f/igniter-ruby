# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/channels"

RSpec.describe Igniter::Channels::Telegram do
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  it "delivers a Telegram message and normalizes the response" do
    response = instance_double(
      Net::HTTPOK,
      body: '{"ok":true,"result":{"message_id":321,"chat":{"id":123456}}}',
      code: "200"
    )
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    captured_request = nil
    allow(http).to receive(:request) do |request|
      captured_request = request
      response
    end

    result = described_class.new(bot_token: "token-1").deliver(
      to: "telegram:123456",
      subject: "Call Summary",
      body: "Lead is interested in a follow-up.",
      metadata: { parse_mode: "Markdown", disable_web_page_preview: true }
    )

    expect(captured_request).to be_a(Net::HTTP::Post)
    expect(captured_request.path).to eq("/bottoken-1/sendMessage")
    expect(captured_request["Content-Type"]).to eq("application/json")

    payload = JSON.parse(captured_request.body)
    expect(payload).to include(
      "chat_id" => "123456",
      "text" => "Call Summary\n\nLead is interested in a follow-up.",
      "parse_mode" => "Markdown",
      "disable_notification" => false
    )
    expect(payload["link_preview_options"]).to eq("is_disabled" => true)

    expect(result.status).to eq(:delivered)
    expect(result.provider).to eq(:telegram)
    expect(result.recipient).to eq("123456")
    expect(result.message_id).to eq(321)
    expect(result.external_id).to eq("321")
  end

  it "supports default chat_id and per-message overrides" do
    response = instance_double(
      Net::HTTPOK,
      body: '{"ok":true,"result":{"message_id":1}}',
      code: "200"
    )
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    captured_payloads = []
    allow(http).to receive(:request) do |request|
      captured_payloads << JSON.parse(request.body)
      response
    end

    channel = described_class.new(
      bot_token: "token-2",
      default_chat_id: "111",
      disable_notification: true
    )

    channel.deliver(body: "default target")
    channel.deliver(body: "override target", metadata: { chat_id: "222", message_thread_id: 7 })

    expect(captured_payloads[0]).to include("chat_id" => "111", "disable_notification" => true)
    expect(captured_payloads[1]).to include("chat_id" => "222", "message_thread_id" => 7)
  end

  it "raises DeliveryError when Telegram returns ok=false" do
    response = instance_double(
      Net::HTTPOK,
      body: '{"ok":false,"description":"Bad Request: chat not found"}',
      code: "200"
    )
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    allow(http).to receive(:request).and_return(response)

    expect {
      described_class.new(bot_token: "token-3", default_chat_id: "123").deliver(body: "hello")
    }.to raise_error(Igniter::Channels::DeliveryError, /chat not found/)
  end

  it "raises DeliveryError when token or chat_id is missing" do
    expect {
      described_class.new(bot_token: nil, default_chat_id: "123").deliver(body: "hello")
    }.to raise_error(Igniter::Channels::DeliveryError, /bot token/)

    expect {
      described_class.new(bot_token: "token-4").deliver(body: "hello")
    }.to raise_error(Igniter::Channels::DeliveryError, /chat_id/)
  end
end
