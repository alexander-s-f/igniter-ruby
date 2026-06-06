# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::LedgerClient::Envelope do
  it "builds a Ledger Open Protocol request envelope" do
    envelope = described_class.request(operation: :read, packet: { store: :orders, key: "o1" }, request_id: "req_1")

    expect(envelope).to eq(
      protocol: :igniter_store,
      schema_version: 1,
      request_id: "req_1",
      op: :read,
      packet: { store: :orders, key: "o1" }
    )
  end

  it "rejects unknown operations" do
    expect { described_class.request(operation: :unknown) }.to raise_error(ArgumentError, /unknown ledger op/)
  end

  it "lists append as a first-class operation" do
    expect(described_class::OPERATIONS).to include(:append)
  end
end
