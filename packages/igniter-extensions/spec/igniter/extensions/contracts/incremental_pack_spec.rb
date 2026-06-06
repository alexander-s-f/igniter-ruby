# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::IncrementalPack do
  it "tracks changed, skipped, and backdated nodes across reruns" do
    environment = Igniter::Extensions::Contracts.with(described_class)
    session = described_class.session(environment) do
      input :x
      input :y

      compute :b, depends_on: [:x] do |x:|
        x * 2
      end

      compute :c, depends_on: [:b] do |b:|
        b + 1
      end

      compute :d, depends_on: [:y] do |y:|
        y.upcase
      end

      output :c
      output :d
    end

    first = session.run(inputs: { x: 5, y: "hello" })
    second = session.run(inputs: { x: 5, y: "world" })

    expect(first.output(:c)).to eq(11)
    expect(second.output(:d)).to eq("WORLD")
    expect(second.skipped_nodes).to include(:b, :c)
    expect(second.changed_outputs).to eq(
      d: { from: "HELLO", to: "WORLD" }
    )
  end

  it "marks backdated nodes when recomputation keeps the same value" do
    environment = Igniter::Extensions::Contracts.with(described_class)
    session = described_class.session(environment) do
      input :x

      compute :b, depends_on: [:x] do |x:| # rubocop:disable Lint/UnusedBlockArgument
        42
      end

      compute :c, depends_on: [:b] do |b:|
        b * 2
      end

      output :c
    end

    session.run(inputs: { x: 1 })
    result = session.run(inputs: { x: 2 })

    expect(result.backdated_nodes).to include(:b)
    expect(result.changed_outputs).to eq({})
    expect(result.outputs_changed?).to eq(false)
  end

  it "requires IncrementalPack to be installed in the environment profile" do
    environment = Igniter::Extensions::Contracts.with

    expect do
      described_class.session(environment) do
        input :amount
        output :amount
      end
    end.to raise_error(Igniter::Contracts::Error, /IncrementalPack is not installed/)
  end
end
