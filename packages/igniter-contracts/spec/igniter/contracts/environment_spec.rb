# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Environment do
  it "builds a finalized profile through the public with helper" do
    environment = Igniter::Contracts.with

    expect(environment).to be_a(described_class)
    expect(environment.profile.pack_names).to eq([:baseline])
  end

  it "compiles and executes against its captured profile" do
    environment = Igniter::Contracts.with(Igniter::Contracts::ProjectPack)

    result = environment.run(inputs: { pricing: { country: "UA" } }) do
      input :pricing
      project :country, from: :pricing, key: :country
      output :country
    end

    expect(result.output(:country)).to eq("UA")
  end

  it "builds reports and effects through the same profile" do
    effect_pack = Module.new do
      extend Igniter::Contracts::Pack

      invocation_log = []

      define_singleton_method(:invocation_log) { invocation_log }

      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :audit_effect,
          registry_contracts: [Igniter::Contracts::PackManifest.effect(:audit)]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel.effects.register(:audit, lambda { |invocation:|
          invocation_log << invocation.to_h
          :ok
        })
        kernel
      end
    end

    environment = Igniter::Contracts.with(effect_pack)

    result = environment.run(inputs: { amount: 10 }) do
      input :amount
      output :amount
    end
    report = environment.diagnose(result)

    expect(report.section(:baseline_summary)).to eq({
                                                      outputs: [:amount],
                                                      state: [:amount]
                                                    })
    expect(environment.apply_effect(:audit, payload: { amount: 10 }, context: { request_id: "req-1" })).to eq(:ok)
    expect(effect_pack.invocation_log.first).to include(
      payload: { amount: 10 },
      context: { request_id: "req-1" }
    )
  end
end
