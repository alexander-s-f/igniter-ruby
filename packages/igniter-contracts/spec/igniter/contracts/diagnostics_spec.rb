# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Diagnostics do
  module ExtraDiagnosticsPack
    module_function

    CONTRIBUTOR = Module.new do
      module_function

      def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
        report.add_section(:extra, {
                             output_count: result.outputs.length
                           })
      end
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :extra_diagnostics,
        registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:extra_diagnostics)]
      )
    end

    def install_into(kernel)
      kernel.diagnostics_contributors.register(:extra_diagnostics, CONTRIBUTOR)
    end
  end

  it "builds a baseline diagnostics report from contributor hooks" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 })
    report = Igniter::Contracts.diagnose(result)

    expect(report.section_object(:baseline_summary)).to be_a(Igniter::Contracts::DiagnosticsSection)
    expect(report.section(:baseline_summary)).to eq({
                                                      outputs: [:amount],
                                                      state: [:amount]
                                                    })
  end

  it "lets packs append diagnostics contributors through the profile" do
    kernel = Igniter::Contracts.build_kernel.install(ExtraDiagnosticsPack)
    profile = kernel.finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      output :amount
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 }, profile: profile)
    report = Igniter::Contracts.diagnose(result, profile: profile)

    expect(report.section_object(:extra)).to be_a(Igniter::Contracts::DiagnosticsSection)
    expect(report.section(:extra)).to eq({ output_count: 1 })
  end
end
