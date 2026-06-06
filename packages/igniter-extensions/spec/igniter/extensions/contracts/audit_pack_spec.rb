# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::AuditPack do
  it "builds an audit snapshot over a plain execution result" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: { amount: 10, country: "UA" }) do
      input :amount
      input :country

      compute :vat_rate, depends_on: [:country] do |country:|
        country == "UA" ? 0.2 : 0.0
      end

      compute :gross_total, depends_on: %i[amount vat_rate] do |amount:, vat_rate:|
        (amount * (1 + vat_rate)).round(2)
      end

      output :gross_total
    end

    snapshot = described_class.snapshot(result)

    expect(snapshot.graph).to include("amount")
    expect(snapshot.event_count).to eq(5)
    expect(snapshot.event_types).to eq(%i[input_observed compute_observed output_observed])
    expect(snapshot.state(:gross_total)).to include(
      kind: :compute,
      status: :succeeded,
      value: 12.0
    )
    expect(snapshot.output_names).to eq([:gross_total])
  end

  it "unwraps wrapper execution results such as incremental session runs" do
    environment = Igniter::Contracts.with(described_class, Igniter::Extensions::Contracts::IncrementalPack)

    session = Igniter::Extensions::Contracts.build_incremental_session(environment) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    wrapper_result = session.run(inputs: { amount: 10 })
    snapshot = described_class.snapshot(wrapper_result)

    expect(snapshot.state(:tax)).to include(kind: :compute, value: 2.0)
    expect(snapshot.event_types).to include(:compute_observed)
  end

  it "contributes audit summaries through diagnostics when installed" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: { amount: 10 }) do
      input :amount
      output :amount
    end

    report = environment.diagnose(result)

    expect(report.section(:audit_summary)).to eq(
      graph: "contracts_graph(amount)",
      event_count: 2,
      event_types: %i[input_observed output_observed],
      state_count: 1,
      output_names: [:amount]
    )
  end
end
