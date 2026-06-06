# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter pending execution" do
  class AsyncQuoteExecutor < Igniter::Executor
    input :order_total, type: :numeric

    def call(order_total:)
      defer(token: "quote-#{order_total}", payload: { job: "pricing_quote" })
    end
  end

  it "returns deferred outputs and marks execution as pending" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric

        compute :quote_total, depends_on: [:order_total], call: AsyncQuoteExecutor
        output :quote_total
      end
    end

    contract = contract_class.new(order_total: 100)

    value = contract.result.quote_total

    expect(value).to be_a(Igniter::Runtime::DeferredResult)
    expect(value.token).to eq("quote-100")
    expect(contract.result.pending?).to eq(true)
    expect(contract.result.success?).to eq(false)
    expect(contract.events.map(&:type)).to include(:node_pending)
  end

  it "propagates pending dependencies to downstream nodes and supports resume" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric

        compute :quote_total, depends_on: [:order_total], call: AsyncQuoteExecutor

        compute :gross_total, depends_on: [:quote_total] do |quote_total:|
          quote_total * 1.2
        end

        output :gross_total
      end
    end

    contract = contract_class.new(order_total: 100)

    deferred = contract.result.gross_total
    expect(deferred).to be_a(Igniter::Runtime::DeferredResult)
    expect(contract.execution.cache.fetch(:gross_total)).to be_pending

    contract.execution.resume(:quote_total, value: 150)

    expect(contract.result.gross_total).to eq(180.0)
    expect(contract.events.map(&:type)).to include(:node_resumed, :node_pending, :node_succeeded)
  end

  it "supports resuming pending nodes by token" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric

        compute :quote_total, depends_on: [:order_total], call: AsyncQuoteExecutor
        output :quote_total
      end
    end

    contract = contract_class.new(order_total: 100)
    contract.result.quote_total

    contract.execution.resume_by_token("quote-100", value: 150)

    expect(contract.result.quote_total).to eq(150)
    expect(contract.result.pending?).to eq(false)
  end

  it "surfaces pending status in diagnostics" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric

        compute :quote_total, depends_on: [:order_total], call: AsyncQuoteExecutor
        output :quote_total
      end
    end

    contract = contract_class.new(order_total: 100)

    report = contract.diagnostics.to_h

    expect(report[:status]).to eq(:pending)
    expect(report[:outputs][:quote_total]).to include(token: "quote-100")
    expect(report[:nodes]).to include(pending: 1)
  end

  it "serializes and restores pending execution snapshots" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric

        compute :quote_total, depends_on: [:order_total], call: AsyncQuoteExecutor

        compute :gross_total, depends_on: [:quote_total] do |quote_total:|
          quote_total * 1.2
        end

        output :gross_total
      end
    end

    original = contract_class.new(order_total: 100)
    original.result.gross_total
    snapshot = original.snapshot

    restored = contract_class.restore(snapshot)

    expect(restored.execution.events.execution_id).to eq(original.execution.events.execution_id)
    expect(restored.result.pending?).to eq(true)
    expect(restored.result.gross_total).to be_a(Igniter::Runtime::DeferredResult)

    restored.execution.resume_by_token("quote-100", value: 150)
    expect(restored.result.gross_total).to eq(180.0)
  end
end
