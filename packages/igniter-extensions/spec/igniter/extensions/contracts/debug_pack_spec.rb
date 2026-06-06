# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::DebugPack do
  it "installs execution_report and provenance as dependency packs" do
    profile = Igniter::Extensions::Contracts.build_profile(described_class)

    expect(profile.pack_names).to include(
      :extensions_debug,
      :extensions_execution_report,
      :extensions_provenance
    )
    expect(profile.declared_registry_keys(:diagnostics_contributors)).to include(
      :debug,
      :execution_report,
      :provenance
    )
  end

  it "builds a profile snapshot with pack and registry details" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    snapshot = Igniter::Extensions::Contracts.debug_profile(environment)

    expect(snapshot.pack_names).to include(:extensions_debug)
    expect(snapshot.registry_keys.fetch(:diagnostics_contributors)).to include(:debug)
    expect(snapshot.to_h.fetch(:packs).map { |pack| pack.fetch(:name) }).to include(:extensions_debug)
  end

  it "builds a full debug report for a successful compile and execution" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    report = Igniter::Extensions::Contracts.debug_report(environment, inputs: { amount: 10 }) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    expect(report.ok?).to eq(true)
    expect(report.execution_result.output(:tax)).to eq(2.0)
    expect(report.diagnostics_report.section_names).to include(:debug, :execution_report, :provenance)
    expect(report.provenance_summary.fetch(:tax)).to include(
      value: 2.0,
      contributing_inputs: { amount: 10 }
    )
  end

  it "returns compile findings without executing when compilation is invalid" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    report = Igniter::Extensions::Contracts.debug_report(environment) do
      output :missing_total
    end

    expect(report.invalid?).to eq(true)
    expect(report.execution_result).to be_nil
    expect(report.compilation_report.findings.map(&:code)).to eq([:missing_output_targets])
  end

  it "builds per-pack snapshots from the active profile" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    snapshot = Igniter::Extensions::Contracts.debug_pack(:extensions_debug, environment)

    expect(snapshot.name).to eq(:extensions_debug)
    expect(snapshot.registry_contracts.fetch(:diagnostics_contributors)).to eq([:debug])
    expect(snapshot.metadata).to eq(category: :developer)
  end

  it "builds debug snapshots for existing execution results" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { amount: 5 }) do
      input :amount
      output :amount
    end

    snapshot = Igniter::Extensions::Contracts.debug_snapshot(result, profile: environment.profile)

    expect(snapshot.execution_result.output(:amount)).to eq(5)
    expect(snapshot.diagnostics_report.section_names).to include(:debug)
  end
end
