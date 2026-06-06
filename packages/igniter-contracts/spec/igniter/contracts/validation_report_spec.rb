# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::ValidationReport do
  it "converts valid reports into compiled graphs" do
    profile = Igniter::Contracts.default_profile
    operations = [
      Igniter::Contracts::Operation.new(kind: :input, name: :amount, attributes: {})
    ]
    report = described_class.new(
      operations: operations,
      findings: [],
      profile_fingerprint: profile.fingerprint
    )

    expect(report).to be_ok
    expect(report.to_compiled_graph.operations).to eq(operations)
  end

  it "raises a validation error when findings are present" do
    finding = Igniter::Contracts::ValidationFinding.new(
      code: :missing_output_targets,
      message: "output targets are not defined: total",
      subjects: [:total]
    )
    report = described_class.new(
      operations: [],
      findings: [finding],
      profile_fingerprint: "fingerprint"
    )

    expect(report).to be_invalid
    expect { report.to_compiled_graph }
      .to raise_error(Igniter::Contracts::ValidationError, /output targets are not defined: total/)
  end
end
