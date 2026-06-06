# frozen_string_literal: true

require "igniter/sdk/channels"

RSpec.describe Igniter::Channels do
  describe Igniter::Channels::Message do
    it "coerces a string into a message body" do
      message = described_class.coerce("hello", to: "chat-1")

      expect(message.to).to eq("chat-1")
      expect(message.body).to eq("hello")
      expect(message.content_type).to eq(:text)
    end

    it "coerces a hash into an immutable message" do
      message = described_class.coerce(
        to: "user@example.com",
        subject: "Welcome",
        metadata: { locale: "en" }
      )

      expect(message.subject).to eq("Welcome")
      expect(message.metadata).to eq(locale: "en")
      expect(message.metadata).to be_frozen
    end

    it "supports cloning via #with" do
      original = described_class.new(to: "chat-1", body: "ping", metadata: { urgent: false })
      updated = original.with(body: "pong", metadata: { urgent: true })

      expect(original.body).to eq("ping")
      expect(updated.body).to eq("pong")
      expect(updated.metadata).to eq(urgent: true)
    end
  end

  describe Igniter::Channels::DeliveryResult do
    it "treats queued, sent, and delivered as success" do
      expect(described_class.new(status: :queued)).to be_success
      expect(described_class.new(status: :sent)).to be_success
      expect(described_class.new(status: :delivered)).to be_success
    end

    it "treats failed and rejected as failure" do
      expect(described_class.new(status: :failed)).to be_failure
      expect(described_class.new(status: :rejected)).to be_failure
    end
  end

  describe Igniter::Channels::Base do
    let(:test_channel_class) do
      Class.new(described_class) do
        def self.name = "TestChannel"

        def deliver_message(message)
          {
            status: :queued,
            external_id: "msg-123",
            payload: { echoed_body: message.body }
          }
        end
      end
    end

    it "defaults to effect_type :messaging" do
      expect(test_channel_class.effect_type).to eq(:messaging)
    end

    it "delivers a coerced message and wraps the result" do
      result = test_channel_class.new.call(to: "chat-1", body: "hello")

      expect(result).to be_a(Igniter::Channels::DeliveryResult)
      expect(result.status).to eq(:queued)
      expect(result.provider).to eq(:test_channel)
      expect(result.recipient).to eq("chat-1")
      expect(result.external_id).to eq("msg-123")
      expect(result.payload).to eq(echoed_body: "hello")
    end

    it "wraps adapter errors in DeliveryError with channel context" do
      failing_channel = Class.new(described_class) do
        def self.name = "FailingChannel"

        def deliver_message(_message)
          raise "boom"
        end
      end

      expect {
        failing_channel.new.call(to: "chat-1", body: "hello")
      }.to raise_error(Igniter::Channels::DeliveryError, /boom/)
    end
  end
end
