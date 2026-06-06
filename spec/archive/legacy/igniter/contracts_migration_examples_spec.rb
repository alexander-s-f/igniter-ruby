# frozen_string_literal: true

require "spec_helper"
require_relative "../../examples/catalog"

RSpec.describe "Igniter contracts migration examples" do
  expected_map = {
    "basic_pricing" => "contracts/basic_pricing",
    "dataflow" => "contracts/dataflow",
    "diagnostics" => "contracts/diagnostics",
    "differential" => "contracts/differential",
    "effects" => "contracts/effects",
    "incremental" => "contracts/incremental",
    "introspection" => "contracts/introspection",
    "invariants" => "contracts/invariants",
    "provenance" => "contracts/provenance",
    "reactive_auditing" => "contracts/reactive",
    "saga" => "contracts/saga"
  }.freeze

  it "tracks direct legacy -> contracts counterparts in the examples catalog" do
    actual_map = IgniterExamples.migration_examples.each_with_object({}) do |example, memo|
      memo[IgniterExamples.normalize(example.migration_of)] = IgniterExamples.normalize(example.id)
    end

    expect(actual_map).to eq(expected_map)
  end

  it "resolves each legacy example to a runnable contracts counterpart" do
    expected_map.each do |legacy_id, contracts_id|
      legacy_example = IgniterExamples.find(legacy_id)
      counterpart = IgniterExamples.counterpart_for(legacy_id)

      aggregate_failures legacy_id do
        expect(legacy_example).not_to be_nil
        expect(counterpart).not_to be_nil
        expect(IgniterExamples.normalize(counterpart.id)).to eq(contracts_id)
        expect(counterpart.path).to start_with("examples/contracts/")
        expect(counterpart).to be_smoke
        expect(counterpart).to be_runnable
      end
    end
  end
end
