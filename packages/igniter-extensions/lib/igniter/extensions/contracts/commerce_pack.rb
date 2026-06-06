# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module CommercePack
        class << self
          def manifest
            Igniter::Contracts::PackManifest.new(
              name: :extensions_commerce,
              requires_packs: [LookupPack, AggregatePack],
              registry_contracts: [
                Igniter::Contracts::PackManifest.dsl_keyword(:order_items),
                Igniter::Contracts::PackManifest.dsl_keyword(:subtotal),
                Igniter::Contracts::PackManifest.dsl_keyword(:tax_amount),
                Igniter::Contracts::PackManifest.dsl_keyword(:grand_total)
              ]
            )
          end

          def install_into(kernel)
            install_dsl_keywords(kernel)
            kernel
          end

          def install_dsl_keywords(kernel)
            kernel.dsl_keywords.register(:order_items, order_items_keyword)
            kernel.dsl_keywords.register(:subtotal, subtotal_keyword)
            kernel.dsl_keywords.register(:tax_amount, tax_amount_keyword)
            kernel.dsl_keywords.register(:grand_total, grand_total_keyword)
          end

          def order_items_keyword
            Igniter::Contracts::DslKeyword.new(:order_items) do |name = :items, from:, builder:, key: :items|
              builder.profile.dsl_keyword(:lookup).call(
                name,
                from: from.to_sym,
                key: key.to_sym,
                builder: builder
              )
            end
          end

          def subtotal_keyword
            Igniter::Contracts::DslKeyword.new(:subtotal) do |name = :subtotal, from:, builder:, amount_key: :amount|
              builder.profile.dsl_keyword(:sum).call(
                name,
                from: from.to_sym,
                using: amount_key.to_sym,
                builder: builder
              )
            end
          end

          def tax_amount_keyword
            Igniter::Contracts::DslKeyword.new(:tax_amount) do |name = :tax, amount:, rate:, builder:|
              dependencies = [amount.to_sym, rate.to_sym]
              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: dependencies,
                callable: lambda do |**values|
                  values.fetch(amount.to_sym) * values.fetch(rate.to_sym)
                end
              )
            end
          end

          def grand_total_keyword
            Igniter::Contracts::DslKeyword.new(:grand_total) do |name = :grand_total, subtotal:, builder:, tax: nil, shipping: nil, discount: nil|
              dependency_names = [subtotal, tax, shipping, discount].compact.map(&:to_sym)

              builder.add_operation(
                kind: :compute,
                name: name,
                depends_on: dependency_names,
                callable: lambda do |**values|
                  total = values.fetch(subtotal.to_sym)
                  total += values.fetch(tax.to_sym) if tax
                  total += values.fetch(shipping.to_sym) if shipping
                  total -= values.fetch(discount.to_sym) if discount
                  total
                end
              )
            end
          end
        end
      end
    end
  end
end
