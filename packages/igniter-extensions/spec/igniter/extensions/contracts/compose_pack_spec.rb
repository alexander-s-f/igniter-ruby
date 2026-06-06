# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::ComposePack do
  it "runs an explicit nested contract and returns the nested execution result by default" do
    environment = Igniter::Contracts.with(described_class)
    pricing_contract = environment.compile do
      input :amount
      input :tax_rate

      compute :tax, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
        amount * tax_rate
      end

      compute :total, depends_on: %i[amount tax] do |amount:, tax:|
        amount + tax
      end

      output :tax
      output :total
    end

    result = environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing, contract: pricing_contract, inputs: {
        amount: :subtotal,
        tax_rate: :rate
      }

      compute :grand_total, depends_on: [:pricing] do |pricing:|
        pricing.output(:total)
      end

      output :grand_total
    end

    expect(result.state.fetch(:pricing)).to be_a(Igniter::Contracts::ExecutionResult)
    expect(result.state.fetch(:pricing).output(:tax)).to eq(20.0)
    expect(result.output(:grand_total)).to eq(120.0)
  end

  it "supports inline nested contracts and explicit output selection" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: { subtotal: 80, rate: 0.25, country: "UA" }) do
      input :subtotal
      input :rate
      input :country

      compose :tax_total, inputs: {
        amount: :subtotal,
        tax_rate: :rate,
        country: :country
      }, output: :total do
        input :amount
        input :tax_rate
        input :country

        compute :rate_multiplier, depends_on: [:country] do |country:|
          country == "UA" ? 1.0 : 1.2
        end

        compute :total, depends_on: %i[amount tax_rate rate_multiplier] do |amount:, tax_rate:, rate_multiplier:|
          amount + (amount * tax_rate * rate_multiplier)
        end

        output :total
      end

      output :tax_total
    end

    expect(result.output(:tax_total)).to eq(100.0)
  end

  it "supports custom invocation adapters through via:" do
    environment = Igniter::Contracts.with(described_class)
    invocations = []
    remote_like_invoker = lambda do |invocation:|
      invocations << {
        operation: invocation.operation.name,
        inputs: invocation.inputs
      }

      Igniter::Contracts.execute(
        invocation.compiled_graph,
        inputs: invocation.inputs,
        profile: invocation.profile
      )
    end

    result = environment.run(inputs: { subtotal: 50, rate: 0.1 }) do
      input :subtotal
      input :rate

      compose :pricing_total, inputs: {
        amount: :subtotal,
        tax_rate: :rate
      }, output: :total, via: remote_like_invoker do
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :pricing_total
    end

    expect(result.output(:pricing_total)).to eq(55.0)
    expect(invocations).to eq([
                                {
                                  operation: :pricing_total,
                                  inputs: { amount: 50, tax_rate: 0.1 }
                                }
                              ])
  end

  it "publishes profile capabilities for nested invocation" do
    profile = Igniter::Contracts.build_profile(described_class)
    manifest = profile.pack_manifest(:extensions_compose)

    expect(profile.pack_names).to include(:extensions_compose)
    expect(manifest.provides_capabilities).to eq(%i[subgraph_invocation nested_contracts])
    expect(profile.provided_capabilities).to include(:subgraph_invocation, :nested_contracts)
  end

  it "fails validation when compose dependencies are missing" do
    environment = Igniter::Contracts.with(described_class)
    pricing_contract = environment.compile do
      input :amount
      output :amount
    end

    expect do
      environment.compile do
        compose :pricing, contract: pricing_contract, inputs: { amount: :subtotal }
        output :pricing
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /compose dependencies are not defined: subtotal/)
  end

  it "fails validation when selected nested outputs are missing" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        input :subtotal

        compose :pricing, inputs: { amount: :subtotal }, output: :missing_total do
          input :amount
          output :amount
        end

        output :pricing
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /compose output selections are not defined/)
  end

  it "fails validation when via: is not callable" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        input :subtotal

        compose :pricing, inputs: { amount: :subtotal }, via: :remote do
          input :amount
          output :amount
        end

        output :pricing
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /compose via: must be callable/)
  end

  it "fails validation when nested contracts were compiled against another profile" do
    compiled_elsewhere = Igniter::Contracts.compile do
      input :amount
      output :amount
    end
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        input :subtotal
        compose :pricing, contract: compiled_elsewhere, inputs: { amount: :subtotal }, output: :amount
        output :pricing
      end
    end.to raise_error(Igniter::Contracts::ValidationError,
                       /compose contracts were compiled against a different profile/)
  end

  it "raises when a custom invoker returns a non-execution result" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.run(inputs: { subtotal: 10 }) do
        input :subtotal

        compose :pricing, inputs: { amount: :subtotal }, via: ->(invocation:) { invocation.inputs } do
          input :amount
          output :amount
        end

        output :pricing
      end
    end.to raise_error(Igniter::Contracts::Error, /must return an ExecutionResult/)
  end
end
