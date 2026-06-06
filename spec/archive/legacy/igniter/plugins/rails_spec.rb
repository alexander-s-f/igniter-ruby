# frozen_string_literal: true

require "spec_helper"
require "igniter/plugins/rails"

RSpec.describe "Igniter Rails Integration" do
  let(:store) { Igniter::Runtime::Stores::MemoryStore.new }

  let(:order_contract) do
    Class.new(Igniter::Contract) do
      correlate_by :order_id

      define do
        input :order_id
        input :amount

        await :payment_confirmed, event: :stripe_webhook_received

        compute :confirmation, depends_on: %i[order_id payment_confirmed] do |order_id:, payment_confirmed:|
          "Order #{order_id} confirmed: #{payment_confirmed[:charge_id]}"
        end

        output :confirmation
      end
    end
  end

  before { stub_const("OrderContract", order_contract) }

  describe Igniter::Rails::WebhookHandler do
    let(:controller_class) do
      Class.new do
        include Igniter::Rails::WebhookHandler

        attr_reader :response_status, :response_body

        def head(status)
          @response_status = status
        end

        def render(json:, status:)
          @response_body = json
          @response_status = status
        end

        def params
          { order_id: "ord-123", charge_id: "ch_abc" }
        end
      end
    end

    let(:controller) { controller_class.new }

    before do
      OrderContract.start({ order_id: "ord-123", amount: 99 }, store: store)
    end

    it "delivers event and responds with 200" do
      controller.deliver_event_for(
        OrderContract,
        event: :stripe_webhook_received,
        correlation_from: { order_id: "ord-123" },
        payload: { charge_id: "ch_abc" },
        store: store
      )

      expect(controller.response_status).to eq(:ok)
    end

    it "renders 422 when no execution found" do
      controller.deliver_event_for(
        OrderContract,
        event: :stripe_webhook_received,
        correlation_from: { order_id: "nonexistent" },
        payload: {},
        store: store
      )

      expect(controller.response_status).to eq(:unprocessable_entity)
      expect(controller.response_body[:error]).to match(/No pending execution/)
    end

    describe "#extract_correlation" do
      it "handles Hash correlation" do
        result = controller.send(:extract_correlation, { order_id: "123" })
        expect(result).to eq({ order_id: "123" })
      end

      it "handles Array of keys" do
        result = controller.send(:extract_correlation, [:order_id])
        expect(result).to eq({ order_id: "ord-123" })
      end
    end
  end

  describe Igniter::Rails::ContractJob do
    describe ".perform_now" do
      it "starts the contract and returns an execution" do
        job = Class.new(Igniter::Rails::ContractJob) do
          contract OrderContract
          store Igniter::Runtime::Stores::MemoryStore.new
        end

        instance = job.perform_now(order_id: "ord-456", amount: 50)
        expect(instance).to be_a(Igniter::Contract)
        expect(instance.pending?).to be true
      end
    end
  end

  describe Igniter::Rails::CableAdapter do
    let(:channel_class) do
      Class.new do
        include Igniter::Rails::CableAdapter

        attr_reader :transmitted_messages

        def transmit(data)
          @transmitted_messages ||= []
          @transmitted_messages << data
        end
      end
    end

    it "can be included without raising" do
      expect { channel_class.new }.not_to raise_error
    end

    it "defines stream_contract method" do
      channel = channel_class.new
      expect(channel).to respond_to(:stream_contract)
    end
  end
end
