# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::CollectionPack do
  it "runs a nested item graph over keyed items and returns a collection result" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: {
                               items: [
                                 { sku: "a", amount: 10 },
                                 { sku: "b", amount: 20 }
                               ],
                               tax_rate: 0.2
                             }) do
      input :items
      input :tax_rate

      collection :priced_items, from: :items, key: :sku, inputs: { tax_rate: :tax_rate } do
        input :sku
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      compute :grand_total, depends_on: [:priced_items] do |priced_items:|
        priced_items.values.sum { |item| item.output(:total) }
      end

      output :priced_items
      output :grand_total
    end

    expect(result.output(:priced_items)).to be_a(Igniter::Extensions::Contracts::Dataflow::CollectionResult)
    expect(result.output(:priced_items).keys).to eq(%w[a b])
    expect(result.output(:priced_items).fetch("a").output(:total)).to eq(12.0)
    expect(result.output(:priced_items).summary).to include(total: 2, added: 2, removed: 0)
    expect(result.output(:grand_total)).to eq(36.0)
  end

  it "supports custom invocation adapters through via:" do
    environment = Igniter::Contracts.with(described_class)
    invocations = []
    remote_like_invoker = lambda do |invocation:|
      invocations << {
        operation: invocation.operation.name,
        item_count: invocation.items.size,
        inputs: invocation.inputs
      }

      described_class::LocalInvoker.call(invocation: invocation)
    end

    result = environment.run(inputs: {
                               items: [
                                 { sku: "a", amount: 5 },
                                 { sku: "b", amount: 15 }
                               ],
                               multiplier: 3
                             }) do
      input :items
      input :multiplier

      collection :scaled_items, from: :items, key: :sku, inputs: { multiplier: :multiplier },
                                via: remote_like_invoker do
        input :sku
        input :amount
        input :multiplier

        compute :scaled_amount, depends_on: %i[amount multiplier] do |amount:, multiplier:|
          amount * multiplier
        end

        output :scaled_amount
      end

      output :scaled_items
    end

    expect(result.output(:scaled_items).fetch("b").output(:scaled_amount)).to eq(45)
    expect(invocations).to eq([
                                {
                                  operation: :scaled_items,
                                  item_count: 2,
                                  inputs: { multiplier: 3 }
                                }
                              ])
  end

  it "publishes profile capabilities and auto-installs orchestration dependencies" do
    profile = Igniter::Contracts.build_profile(described_class)
    manifest = profile.pack_manifest(:extensions_collection)

    expect(profile.pack_names).to include(
      :extensions_collection,
      :extensions_dataflow,
      :extensions_incremental
    )
    expect(manifest.requires_packs.map(&:name)).to eq(%i[extensions_dataflow extensions_incremental])
    expect(manifest.provides_capabilities).to eq(%i[collection keyed_sessions incremental_collection])
    expect(profile.provided_capabilities).to include(:collection, :keyed_sessions, :incremental_collection)
  end

  it "fails validation when collection dependencies are missing" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        collection :priced_items, from: :items, key: :sku, inputs: { tax_rate: :tax_rate } do
          input :sku
          input :amount
          input :tax_rate
          output :amount
        end

        output :priced_items
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /collection dependencies are not defined: items, tax_rate/)
  end

  it "fails validation when via: is not callable" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        input :items

        collection :priced_items, from: :items, key: :sku, via: :remote do
          input :sku
          output :sku
        end

        output :priced_items
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /collection via: must be callable/)
  end

  it "fails validation when item graphs were compiled against another profile" do
    compiled_elsewhere = Igniter::Contracts.compile do
      input :sku
      output :sku
    end
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.compile do
        input :items
        collection :priced_items, from: :items, key: :sku, contract: compiled_elsewhere
        output :priced_items
      end
    end.to raise_error(Igniter::Contracts::ValidationError,
                       /collection item graphs were compiled against a different profile/)
  end

  it "raises when a custom invoker returns a non-collection result" do
    environment = Igniter::Contracts.with(described_class)

    expect do
      environment.run(inputs: { items: [{ sku: "a" }] }) do
        input :items

        collection :priced_items, from: :items, key: :sku, via: ->(invocation:) { invocation.items } do
          input :sku
          output :sku
        end

        output :priced_items
      end
    end.to raise_error(Igniter::Contracts::Error, /must return a CollectionResult/)
  end
end
