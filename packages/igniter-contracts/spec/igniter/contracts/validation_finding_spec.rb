# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::ValidationFinding do
  it "captures structured validation metadata" do
    finding = described_class.new(
      code: "missing_output_targets",
      message: "output targets are not defined: total",
      subjects: ["total"],
      metadata: { phase: :compile }
    )

    expect(finding.code).to eq(:missing_output_targets)
    expect(finding.message).to eq("output targets are not defined: total")
    expect(finding.subjects).to eq([:total])
    expect(finding.metadata).to eq({ phase: :compile })
    expect(finding).to be_frozen
  end
end
