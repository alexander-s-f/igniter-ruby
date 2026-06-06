# frozen_string_literal: true

require "spec_helper"
require "igniter/core"

RSpec.describe Igniter::DTO::Record do
  let(:example_class) do
    Class.new(described_class) do
      field :name, required: true, coerce: ->(value) { value.to_s.strip }
      field :status, default: :pending, coerce: ->(value) { value.to_sym }
      field :metadata, default: -> { {} }, coerce: :normalize_metadata, merge: true

      def self.normalize_metadata(hash)
        (hash || {}).each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end
    end
  end

  it "declares immutable fields with defaults and coercion" do
    record = example_class.new(name: "  Alpha  ")

    expect(record.name).to eq("Alpha")
    expect(record.status).to eq(:pending)
    expect(record.metadata).to eq({})
    expect(record).to be_frozen
  end

  it "supports from_h and to_h round-trip" do
    record = example_class.from_h("name" => "Alpha", "status" => "ready", "metadata" => { "lane" => "ops" })

    expect(record.to_h).to eq(
      name: "Alpha",
      status: :ready,
      metadata: { lane: "ops" }
    )
  end

  it "preserves subclasses and merges opted-in hash fields via with" do
    subclass = Class.new(example_class)
    record = subclass.new(name: "Alpha", metadata: { lane: "ops" })

    derived = record.with(status: :ready, metadata: { owner: "alex" })

    expect(derived).to be_a(subclass)
    expect(derived.status).to eq(:ready)
    expect(derived.metadata).to eq(lane: "ops", owner: "alex")
  end

  it "rejects unknown fields" do
    expect do
      example_class.new(name: "Alpha", extra: true)
    end.to raise_error(ArgumentError, /unknown fields/)
  end

  it "rejects missing required fields" do
    expect do
      example_class.new
    end.to raise_error(ArgumentError, /requires name/)
  end
end
