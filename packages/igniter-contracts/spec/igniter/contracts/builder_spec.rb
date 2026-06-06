# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Builder do
  it "compiles baseline keywords through the profile registry" do
    compiled = Igniter::Contracts.compile do
      input :amount, type: :numeric
      const :tax_rate, 0.2
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    expect(compiled.operations.map(&:kind)).to eq(%i[input const compute output])
    expect(compiled.operations.map(&:name)).to eq(%i[amount tax_rate tax tax])
    expect(compiled.profile_fingerprint).to eq(Igniter::Contracts.default_profile.fingerprint)
    expect(compiled.operations[2].attributes[:callable]).to respond_to(:call)
  end

  it "compiles effect nodes through the baseline profile when an adapter pack is installed" do
    effect_pack = Module.new do
      extend Igniter::Contracts::Pack

      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :audit_effect,
          registry_contracts: [Igniter::Contracts::PackManifest.effect(:audit)]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel.effects.register(:audit, ->(invocation:) { invocation.payload })
        kernel
      end
    end

    profile = Igniter::Contracts.build_kernel.install(effect_pack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      effect :audit_entry, using: :audit, depends_on: [:amount] do |amount:|
        { amount: amount }
      end
      output :audit_entry
    end

    expect(compiled.operations.map(&:kind)).to eq(%i[input effect output])
    expect(compiled.operations[1].attributes[:using]).to eq(:audit)
    expect(compiled.operations[1].attributes[:depends_on]).to eq([:amount])
    expect(compiled.operations[1].attributes[:callable]).to respond_to(:call)
  end

  it "raises a contracts-owned error for unknown keywords" do
    expect do
      Igniter::Contracts.compile do
        remote :tax_service
      end
    end.to raise_error(Igniter::Contracts::UnknownDslKeywordError, /unknown DSL keyword remote/)
  end

  it "keeps explicit ConstPack installation compatible with baseline const support" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ConstPack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      const :tax_rate, 0.2
      output :tax_rate
    end

    expect(profile.supports_node_kind?(:const)).to be(true)
    expect(profile.pack_names).to eq(%i[baseline const])
    expect(compiled.operations.map(&:kind)).to eq(%i[const output])
    expect(compiled.operations.first.attributes).to eq({ value: 0.2 })
  end
end
