# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Runtime do
  it "executes a baseline input-compute-output flow" do
    compiled = Igniter::Contracts.compile do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 })

    expect(result.output(:tax)).to eq(2.0)
    expect(result.state).to be_a(Igniter::Contracts::NamedValues)
    expect(result.outputs).to be_a(Igniter::Contracts::NamedValues)
    expect(result.compiled_graph).to eq(compiled)
    expect(result.state.fetch(:amount)).to eq(10)
    expect(result.state.fetch(:tax)).to eq(2.0)
  end

  it "executes baseline const nodes without extra packs" do
    compiled = Igniter::Contracts.compile do
      const :tax_rate, 0.2
      output :tax_rate
    end

    result = Igniter::Contracts.execute(compiled, inputs: {})

    expect(result.output(:tax_rate)).to eq(0.2)
  end

  it "executes through the explicit inline executor seam" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    result = Igniter::Contracts.execute_with(:inline, compiled, inputs: { amount: 15 })

    expect(result.output(:amount)).to eq(15)
  end

  it "executes baseline effect nodes through profile-installed adapters" do
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
          invocation.payload.merge(status: "logged")
        })
        kernel
      end
    end
    profile = Igniter::Contracts.build_kernel.install(effect_pack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      effect :audit_entry, using: :audit, depends_on: [:amount] do |amount:|
        { amount: amount, event: "quoted" }
      end
      output :audit_entry
    end

    result = Igniter::Contracts.execute(compiled, inputs: { amount: 10 }, profile: profile)

    expect(result.output(:audit_entry)).to eq(amount: 10, event: "quoted", status: "logged")
    expect(result.state.fetch(:audit_entry)).to eq(amount: 10, event: "quoted", status: "logged")
    expect(effect_pack.invocation_log).to eq([{
                                               payload: { amount: 10, event: "quoted" },
                                               context: {
                                                 node_name: :audit_entry,
                                                 effect_name: :audit,
                                                 dependencies: { amount: 10 }
                                               },
                                               profile_fingerprint: profile.fingerprint
                                             }])
  end

  it "executes an explicit profile with the project pack" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :pricing
      project :country, from: :pricing, key: :country
      output :country
    end

    result = Igniter::Contracts.execute(
      compiled,
      inputs: { pricing: { country: "UA" } },
      profile: profile
    )

    expect(result.output(:country)).to eq("UA")
    expect(result.state.fetch(:country)).to eq("UA")
    expect(compiled.operations.map(&:kind)).to eq(%i[input compute output])
  end

  it "supports project dig: paths and default: lowering through compute semantics" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :pricing
      project :country, from: :pricing, dig: %i[billing address country]
      project :postal_code, from: :pricing, dig: %i[billing address postal_code], default: "unknown"
      output :country
      output :postal_code
    end

    result = Igniter::Contracts.execute(
      compiled,
      inputs: { pricing: { billing: { address: { country: "UA" } } } },
      profile: profile
    )

    expect(result.output(:country)).to eq("UA")
    expect(result.output(:postal_code)).to eq("unknown")
  end

  it "rejects execution against a different profile fingerprint" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    other_profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ConstPack).finalize

    expect do
      Igniter::Contracts.execute(compiled, inputs: { amount: 10 }, profile: other_profile)
    end.to raise_error(Igniter::Contracts::ProfileMismatchError, /does not match profile/)
  end
end
