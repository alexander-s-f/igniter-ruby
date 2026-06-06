# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::ContentAddressingPack do
  before do
    described_class.reset_cache!
  end

  it "builds stable content keys independent of input hash order" do
    key_a = described_class.content_key(fingerprint: "tax_v1", inputs: { country: :ua, amount: 100 })
    key_b = described_class.content_key(fingerprint: "tax_v1", inputs: { amount: 100, country: :ua })

    expect(key_a).to eq(key_b)
    expect(key_a.to_s).to start_with("ca:")
  end

  it "wraps a callable with explicit capabilities and fingerprint" do
    wrapped = described_class.content_addressed(fingerprint: "tax_v1") { |amount:| amount * 0.2 }

    expect(wrapped.declared_capabilities).to eq([:pure])
    expect(wrapped.content_fingerprint).to eq("tax_v1")
    expect(wrapped.call(amount: 10)).to eq(2.0)
  end

  it "reuses cached results across independent executions with identical inputs" do
    calls = []
    wrapped = described_class.content_addressed(fingerprint: "tax_v1") do |amount:|
      calls << :called
      amount * 0.2
    end

    environment = Igniter::Contracts.with(described_class)
    compiled = environment.compile do
      input :amount
      compute :tax, depends_on: [:amount], callable: wrapped
      output :tax
    end

    first = environment.execute(compiled, inputs: { amount: 100 })
    second = environment.execute(compiled, inputs: { amount: 100 })

    expect(first.output(:tax)).to eq(20.0)
    expect(second.output(:tax)).to eq(20.0)
    expect(calls.length).to eq(1)
    expect(described_class.stats).to include(size: 1, hits: 1, misses: 1)
  end

  it "computes different content keys when inputs change" do
    wrapped = described_class.content_addressed(fingerprint: "tax_v1") { |amount:| amount * 0.2 }

    key_a = described_class.content_key(callable: wrapped, inputs: { amount: 100 })
    key_b = described_class.content_key(callable: wrapped, inputs: { amount: 120 })

    expect(key_a).not_to eq(key_b)
  end

  it "uses proc source location as the default fingerprint when none is provided" do
    wrapped = described_class.content_addressed { |amount:| amount * 0.2 }

    expect(wrapped.content_fingerprint).to start_with("proc:")
  end
end
