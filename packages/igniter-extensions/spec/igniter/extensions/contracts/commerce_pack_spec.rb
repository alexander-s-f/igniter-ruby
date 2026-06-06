# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::CommercePack do
  it "builds an order pricing flow through domain DSL keywords" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: {
                               order: {
                                 items: [
                                   { amount: 10 },
                                   { amount: 20 }
                                 ]
                               },
                               tax_rate: 0.2,
                               shipping: 5,
                               discount: 3
                             }) do
      input :order
      input :tax_rate
      input :shipping
      input :discount
      order_items from: :order
      subtotal from: :items
      tax_amount amount: :subtotal, rate: :tax_rate
      grand_total subtotal: :subtotal, tax: :tax, shipping: :shipping, discount: :discount
      output :subtotal
      output :tax
      output :grand_total
    end

    expect(result.output(:subtotal)).to eq(30)
    expect(result.output(:tax)).to eq(6.0)
    expect(result.output(:grand_total)).to eq(38.0)
  end

  it "installs its dependent packs and exposes a coherent profile story" do
    profile = Igniter::Contracts.build_profile(described_class)
    manifest = profile.pack_manifest(:extensions_commerce)

    expect(profile.pack_names).to contain_exactly(
      :baseline,
      :extensions_lookup,
      :extensions_aggregate,
      :extensions_commerce
    )
    expect(manifest.requires_packs.map(&:name)).to eq(%i[extensions_lookup extensions_aggregate])
    expect(profile.dsl_keyword(:lookup)).to be_a(Igniter::Contracts::DslKeyword)
    expect(profile.supports_node_kind?(:lookup)).to be(false)
    expect(profile.dsl_keyword(:sum)).to be_a(Igniter::Contracts::DslKeyword)
    expect(profile.supports_node_kind?(:sum)).to be(false)
    expect(profile.dsl_keyword(:grand_total)).to be_a(Igniter::Contracts::DslKeyword)
  end

  it "supports custom names and amount keys" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: {
                               invoice: {
                                 lines: [
                                   { cents: 1500 },
                                   { cents: 2500 }
                                 ]
                               },
                               vat_rate: 0.1
                             }) do
      input :invoice
      input :vat_rate
      order_items :lines, from: :invoice, key: :lines
      subtotal :net_total, from: :lines, amount_key: :cents
      tax_amount :vat_amount, amount: :net_total, rate: :vat_rate
      grand_total :gross_total, subtotal: :net_total, tax: :vat_amount
      output :gross_total
    end

    expect(result.output(:gross_total)).to eq(4400.0)
  end
end
