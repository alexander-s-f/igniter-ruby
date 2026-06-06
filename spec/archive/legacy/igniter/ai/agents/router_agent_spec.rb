# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::RouterAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  describe "on :register_route" do
    it "adds an intent → handler mapping" do
      handler = ->(task:, **) {}
      result  = call_handler(:register_route,
        payload: { intent: :refund, handler: handler })
      expect(result[:routes]).to have_key(:refund)
    end

    it "coerces intent to symbol" do
      handler = ->(task:, **) {}
      result  = call_handler(:register_route,
        payload: { intent: "shipping", handler: handler })
      expect(result[:routes]).to have_key(:shipping)
    end

    it "overwrites an existing route for the same intent" do
      h1     = ->(task:, **) {}
      h2     = ->(task:, **) {}
      state  = call_handler(:register_route, payload: { intent: :x, handler: h1 })
      result = call_handler(:register_route, state: state,
        payload: { intent: :x, handler: h2 })
      expect(result[:routes][:x]).to equal(h2)
    end
  end

  describe "on :remove_route" do
    it "removes the intent from routes" do
      state  = call_handler(:register_route,
        payload: { intent: :x, handler: -> {} })
      result = call_handler(:remove_route, state: state, payload: { intent: :x })
      expect(result[:routes]).not_to have_key(:x)
    end
  end

  describe "on :set_fallback" do
    it "stores the fallback handler" do
      fallback = ->(task:, **) {}
      result   = call_handler(:set_fallback, payload: { handler: fallback })
      expect(result[:fallback_handler]).to equal(fallback)
    end
  end

  describe "on :configure_llm" do
    it "stores the LLM executor" do
      executor = double("LLM")
      result   = call_handler(:configure_llm, payload: { executor: executor })
      expect(result[:llm]).to equal(executor)
    end
  end

  describe "on :route — keyword classification" do
    let(:refund_handler)   { double("refund",   call: nil) }
    let(:shipping_handler) { double("shipping", call: nil) }

    let(:state) do
      routes = { refund: refund_handler, shipping: shipping_handler }
      described_class.default_state.merge(routes: routes)
    end

    it "dispatches to matching handler by keyword" do
      allow(refund_handler).to receive(:call)
      call_handler(:route, state: state,
        payload: { task: "I need a refund please" })
      expect(refund_handler).to have_received(:call)
        .with(task: "I need a refund please", intent: :refund, context: {})
    end

    it "is case-insensitive" do
      allow(shipping_handler).to receive(:call)
      call_handler(:route, state: state,
        payload: { task: "WHERE IS MY SHIPPING?" })
      expect(shipping_handler).to have_received(:call)
    end

    it "calls on_unrouted when no match found" do
      received = {}
      on_unrouted = ->(task:, intent:) { received.merge!(task: task, intent: intent) }
      call_handler(:route, state: state,
        payload: { task: "something unrelated", on_unrouted: on_unrouted })
      expect(received[:task]).to eq("something unrelated")
    end

    it "calls fallback handler when no match and no on_unrouted" do
      fallback = double("fallback")
      allow(fallback).to receive(:call)
      state_with_fallback = state.merge(fallback_handler: fallback)
      call_handler(:route, state: state_with_fallback,
        payload: { task: "totally unrelated" })
      expect(fallback).to have_received(:call)
    end

    it "returns state unchanged" do
      result = call_handler(:route, state: state,
        payload: { task: "I need a refund" })
      expect(result).to eq(state)
    end
  end

  describe "on :route — LLM classification" do
    let(:handler) { double("handler", call: nil) }
    let(:llm) do
      double("LLM").tap do |d|
        allow(d).to receive(:call).and_return({ intent: "billing" })
      end
    end

    let(:state) do
      described_class.default_state.merge(
        routes: { billing: handler },
        llm:    llm
      )
    end

    it "calls LLM with task, context, and intent names" do
      call_handler(:route, state: state, payload: { task: "charge me" })
      expect(llm).to have_received(:call).with(
        hash_including(task: "charge me", intents: ["billing"])
      )
    end

    it "dispatches to the LLM-classified handler" do
      allow(handler).to receive(:call)
      call_handler(:route, state: state, payload: { task: "charge me" })
      expect(handler).to have_received(:call)
    end

    it "falls back to keyword matching when LLM raises" do
      allow(handler).to receive(:call)
      allow(llm).to receive(:call).and_raise(RuntimeError, "provider down")
      call_handler(:route, state: state, payload: { task: "billing question" })
      expect(handler).to have_received(:call)
    end
  end

  describe "on :routes" do
    it "returns RouteInfo structs for all registered intents" do
      state = call_handler(:register_route,
        payload: { intent: :refund, handler: -> {} })
      result = call_handler(:routes, state: state)
      expect(result).to all(be_a(described_class::RouteInfo))
      expect(result.map(&:intent)).to include(:refund)
    end

    it "returns empty array when no routes registered" do
      expect(call_handler(:routes)).to be_empty
    end
  end
end
