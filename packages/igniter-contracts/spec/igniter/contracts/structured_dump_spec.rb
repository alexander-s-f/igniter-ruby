# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts structured serialization" do
  it "serializes compilation reports into stable nested hashes" do
    report = Igniter::Contracts.compilation_report do
      input :amount
      output :amount
    end

    expect(report.to_h).to eq(
      operations: [
        { kind: :input, name: :amount, attributes: {} },
        { kind: :output, name: :amount, attributes: {} }
      ],
      validation_report: {
        operations: [
          { kind: :input, name: :amount, attributes: {} },
          { kind: :output, name: :amount, attributes: {} }
        ],
        findings: [],
        profile_fingerprint: report.profile_fingerprint,
        ok: true
      },
      compiled_graph: {
        operations: [
          { kind: :input, name: :amount, attributes: {} },
          { kind: :output, name: :amount, attributes: {} }
        ],
        profile_fingerprint: report.profile_fingerprint
      },
      profile_fingerprint: report.profile_fingerprint,
      ok: true
    )
  end

  it "serializes diagnostics reports and validation errors for tooling" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end
    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 })
    diagnostics = Igniter::Contracts.diagnose(result)

    expect(diagnostics.to_h).to eq(
      sections: {
        baseline_summary: {
          name: :baseline_summary,
          value: {
            outputs: [:amount],
            state: [:amount]
          }
        }
      }
    )

    error =
      begin
        Igniter::Contracts.compile do
          output :missing_total
        end
      rescue Igniter::Contracts::ValidationError => e
        e
      end

    expect(error.to_h).to eq(
      message: "output targets are not defined: missing_total",
      findings: [
        {
          code: :missing_output_targets,
          message: "output targets are not defined: missing_total",
          subjects: [:missing_total],
          metadata: {}
        }
      ]
    )
  end

  it "serializes execution results together with their compiled graph for tooling" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 })

    expect(result.to_h).to eq(
      state: { amount: 10 },
      outputs: { amount: 10 },
      profile_fingerprint: result.profile_fingerprint,
      compiled_graph: {
        operations: [
          { kind: :input, name: :amount, attributes: {} },
          { kind: :output, name: :amount, attributes: {} }
        ],
        profile_fingerprint: result.profile_fingerprint
      }
    )
  end
end
