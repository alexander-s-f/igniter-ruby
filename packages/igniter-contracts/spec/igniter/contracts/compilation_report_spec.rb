# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::CompilationReport do
  it "exposes compiled graph and findings through a single typed object" do
    profile = Igniter::Contracts.default_profile
    operations = [
      Igniter::Contracts::Operation.new(kind: :input, name: :amount, attributes: {})
    ]
    validation_report = Igniter::Contracts::ValidationReport.new(
      operations: operations,
      findings: [],
      profile_fingerprint: profile.fingerprint
    )
    compiled_graph = Igniter::Contracts::CompiledGraph.new(
      operations: operations,
      profile_fingerprint: profile.fingerprint
    )

    report = described_class.new(
      operations: operations,
      validation_report: validation_report,
      compiled_graph: compiled_graph,
      profile_fingerprint: profile.fingerprint
    )

    expect(report).to be_ok
    expect(report.findings).to eq([])
    expect(report.to_compiled_graph).to equal(compiled_graph)
  end

  it "raises through the embedded validation report when invalid" do
    finding = Igniter::Contracts::ValidationFinding.new(
      code: :missing_output_targets,
      message: "output targets are not defined: total",
      subjects: [:total]
    )
    validation_report = Igniter::Contracts::ValidationReport.new(
      operations: [],
      findings: [finding],
      profile_fingerprint: "fingerprint"
    )
    report = described_class.new(
      operations: [],
      validation_report: validation_report,
      compiled_graph: nil,
      profile_fingerprint: "fingerprint"
    )

    expect(report).to be_invalid
    expect { report.to_compiled_graph }
      .to raise_error(Igniter::Contracts::ValidationError, /output targets are not defined: total/)
  end
end
