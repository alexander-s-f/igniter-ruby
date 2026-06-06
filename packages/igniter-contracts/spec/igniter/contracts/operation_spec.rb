# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Operation do
  it "exposes a typed immutable interface for execution operations" do
    operation = described_class.new(
      kind: "compute",
      name: "tax",
      attributes: { "depends_on" => [:amount] }
    )

    expect(operation.kind).to eq(:compute)
    expect(operation.name).to eq(:tax)
    expect(operation.attributes).to eq({ depends_on: [:amount] })
    expect(operation).to be_frozen
  end

  it "creates updated copies through with_attributes" do
    operation = described_class.new(kind: :input, name: :amount, attributes: { type: :numeric })
    updated = operation.with_attributes(type: :decimal)

    expect(updated.kind).to eq(:input)
    expect(updated.name).to eq(:amount)
    expect(updated.attributes).to eq({ type: :decimal })
    expect(operation.attributes).to eq({ type: :numeric })
  end
end
