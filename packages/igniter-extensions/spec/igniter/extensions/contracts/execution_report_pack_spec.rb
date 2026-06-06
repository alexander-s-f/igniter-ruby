# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::ExecutionReportPack do
  it "installs as an external contracts pack and contributes diagnostics through the public profile" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 }, profile: profile)
    report = Igniter::Contracts.diagnose(result, profile: profile)

    expect(profile.pack_names).to include(:baseline, :extensions_execution_report)
    expect(report.section(:execution_report)).to eq({
                                                      profile_fingerprint: profile.fingerprint,
                                                      pack_names: %i[baseline extensions_execution_report],
                                                      output_count: 1,
                                                      state_count: 2,
                                                      outputs: { tax: 2.0 },
                                                      state_keys: %i[amount tax]
                                                    })
  end
end
