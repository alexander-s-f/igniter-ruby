# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Store::Fact do
  it "uses stable content hashes independent of hash insertion order" do
    first  = described_class.build(store: :items, key: "a", value: { b: 2, a: 1 })
    second = described_class.build(store: :items, key: "b", value: { a: 1, b: 2 })

    expect(first.value_hash).to eq(second.value_hash)
  end

  it "assigns a unique UUID id to each fact regardless of content" do
    f1 = described_class.build(store: :items, key: "a", value: { x: 1 })
    f2 = described_class.build(store: :items, key: "a", value: { x: 1 })

    expect(f1.id).not_to eq(f2.id)
    expect(f1.value_hash).to eq(f2.value_hash)
  end

  it "sets causation to the previous fact id, not the value hash" do
    f1 = described_class.build(store: :items, key: "a", value: { v: 1 })
    f2 = described_class.build(store: :items, key: "a", value: { v: 2 }, causation: f1.id)

    expect(f2.causation).to eq(f1.id)
    expect(f2.causation).not_to eq(f1.value_hash)
  end

  it "causation chain is unambiguous when the same value is written twice" do
    f1 = described_class.build(store: :items, key: "a", value: { status: :open })
    f2 = described_class.build(store: :items, key: "a", value: { status: :open }, causation: f1.id)

    # Same content → same value_hash, but each fact has a distinct id
    expect(f1.value_hash).to eq(f2.value_hash)
    expect(f2.causation).to eq(f1.id)
    expect(f2.causation).not_to eq(f2.value_hash)
  end

  it "exposes the canonical pre-v1 fact fields" do
    fact = described_class.build(
      store: :items,
      key: "a",
      value: { status: :open },
      valid_time: 1_714_200_123.5,
      producer: { system: :spec, name: :FactSpec },
      derivation: { name: :demo_derivation, source_fact_ids: ["source-1"] }
    )

    expect(fact.transaction_time).to be_a(Float)
    expect(fact.timestamp).to eq(fact.transaction_time)
    expect(fact.valid_time).to eq(1_714_200_123.5)
    expect(fact.term).to eq(1_714_200_123.5)
    expect(fact.producer[:system]).to eq(:spec)
    expect(fact.derivation[:name]).to eq(:demo_derivation)
    expect(fact.to_h).to include(
      transaction_time: fact.transaction_time,
      valid_time: 1_714_200_123.5,
      producer: fact.producer,
      derivation: fact.derivation
    )
  end

  it "accepts legacy timestamp and term keys when rebuilding from a hash" do
    fact = described_class.from_h(
      id: "fact-1",
      store: :items,
      key: "a",
      value: { status: :open },
      value_hash: "hash-1",
      causation: nil,
      timestamp: 1_714_200_000.0,
      term: 1_714_200_123.5,
      schema_version: 1,
      producer: { system: :legacy },
      derivation: { name: :legacy_derivation }
    )

    expect(fact.transaction_time).to be_a(Float)
    expect(fact.valid_time).to eq(1_714_200_123.5)
    expect(fact.producer[:system]).to eq(:legacy)
    expect(fact.derivation[:name]).to eq(:legacy_derivation)
  end
end
