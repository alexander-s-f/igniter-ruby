# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::NamedValues do
  it "provides an immutable symbol-keyed lookup interface" do
    values = described_class.new("amount" => 10, tax: 2)

    expect(values.fetch(:amount)).to eq(10)
    expect(values[:tax]).to eq(2)
    expect(values.key?(:amount)).to be(true)
    expect(values.keys).to eq(%i[amount tax])
    expect(values.length).to eq(2)
    expect(values.to_h).to eq({ amount: 10, tax: 2 })
    expect(values).to be_frozen
  end
end
