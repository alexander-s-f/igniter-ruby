# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::CapabilitiesPack do
  it "declares capabilities on wrapped callables" do
    callable = described_class.declare(:network, :external_api) { |x:| x }

    expect(callable.declared_capabilities).to eq(%i[network external_api])
    expect(callable.call(x: 1)).to eq(1)
  end

  it "collects required capabilities from operation attributes and wrapped callables" do
    environment = Igniter::Contracts.with(described_class)
    wrapped = described_class.declare(:database) { |sku:| sku.upcase }

    compiled = environment.compile do
      input :sku
      compute :fetched, depends_on: [:sku], capabilities: [:network], callable: wrapped
      output :fetched
    end

    expect(described_class.required_capabilities(compiled)).to eq(
      fetched: %i[network database]
    )
    expect(described_class.capabilities_for(compiled, :fetched)).to eq(%i[network database])
  end

  it "builds policy reports and raises on denied capabilities" do
    environment = Igniter::Contracts.with(described_class)

    compiled = environment.compile do
      input :sku
      compute :fetched, depends_on: [:sku], capabilities: [:network] do |sku:|
        sku
      end
      output :fetched
    end

    policy = described_class.policy(denied: [:network])
    report = described_class.report(compiled, profile: environment.profile, policy: policy)

    expect(report.invalid?).to eq(true)
    expect(report.violations.first.kind).to eq(:denied_capability)
    expect { described_class.check!(compiled, profile: environment.profile, policy: policy) }
      .to raise_error(Igniter::Extensions::Contracts::Capabilities::CapabilityViolationError, /network/)
  end

  it "supports undeclared-node enforcement for stronger upper-layer preflight" do
    environment = Igniter::Contracts.with(described_class)

    compiled = environment.compile do
      input :amount
      compute :total, depends_on: [:amount] do |amount:|
        amount * 1.2
      end
      output :total
    end

    report = described_class.report(
      compiled,
      policy: described_class.policy(on_undeclared: :error)
    )

    expect(report.invalid?).to eq(true)
    expect(report.undeclared_nodes).to include(:amount, :total)
    expect(report.violations.map(&:kind)).to include(:undeclared_capabilities)
  end

  it "surfaces pack-level profile capabilities from manifest capability declarations" do
    pack = Module.new do
      module_function

      def manifest
        Igniter::Contracts::PackManifest.new(
          name: :ops_pack,
          provides_capabilities: %i[network messaging]
        )
      end

      def install_into(kernel)
        kernel
      end
    end

    environment = Igniter::Contracts.with(described_class, pack)

    expect(described_class.profile_capabilities(environment.profile)).to eq(%i[network messaging])
  end
end
