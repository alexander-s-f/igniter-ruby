# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::SagaPack do
  it "runs compensations in reverse completion order after a failure" do
    environment = Igniter::Extensions::Contracts.with(described_class)
    compensation_log = []

    compensations = described_class.build do
      compensate :charge_card do |inputs:, value:|
        compensation_log << { node: :charge_card, inputs: inputs, value: value }
      end

      compensate :reserve_stock do |inputs:, value:|
        compensation_log << { node: :reserve_stock, inputs: inputs, value: value }
      end
    end

    result = described_class.run(
      environment,
      inputs: { order_id: "ord-1", amount: 999.0 },
      compensations: compensations
    ) do
      input :order_id
      input :amount

      compute :reserve_stock, depends_on: [:order_id] do |order_id:|
        { reservation_id: "rsv-#{order_id}" }
      end

      compute :charge_card, depends_on: %i[order_id amount reserve_stock] do |order_id:, amount:, **|
        raise "declined #{order_id}" if amount > 500

        { charge_id: "chg-#{order_id}", amount: amount }
      end

      output :charge_card
    end

    expect(result.failed?).to eq(true)
    expect(result.failed_node).to eq(:charge_card)
    expect(result.error.message).to include("declined ord-1")
    expect(result.compensations.map(&:node_name)).to eq([:reserve_stock])
    expect(compensation_log).to eq([{
                                     node: :reserve_stock,
                                     inputs: { order_id: "ord-1" },
                                     value: { reservation_id: "rsv-ord-1" }
                                   }])
  end

  it "returns a successful result without compensations when execution completes" do
    environment = Igniter::Extensions::Contracts.with(described_class)
    compensations = described_class.build do
      compensate(:amount) { |**| raise "should not run" }
    end

    result = described_class.run(
      environment,
      inputs: { amount: 15 },
      compensations: compensations
    ) do
      input :amount
      output :amount
    end

    expect(result.success?).to eq(true)
    expect(result.output(:amount)).to eq(15)
    expect(result.compensations).to eq([])
    expect(result.execution_result.outputs.to_h).to eq(amount: 15)
  end

  it "requires SagaPack to be installed in the environment profile" do
    environment = Igniter::Extensions::Contracts.with
    compensations = described_class.build {}

    expect do
      described_class.run(
        environment,
        inputs: { amount: 1 },
        compensations: compensations
      ) do
        input :amount
        output :amount
      end
    end.to raise_error(Igniter::Extensions::Contracts::Saga::SagaError, /SagaPack is not installed/)
  end
end
