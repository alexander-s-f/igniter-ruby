# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter DSL ergonomics" do
  it "supports const nodes without dependencies" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        const :vendor_id, "eLocal"
        output :vendor_id
      end
    end

    contract = contract_class.new

    expect(contract.result.vendor_id).to eq("eLocal")
    expect(contract.class.graph.to_text).to include("compute vendor_id callable=const const=true")
  end

  it "supports lookup as a semantic compute alias" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :trade_name, type: :string

        lookup :trade, with: :trade_name do |trade_name:|
          { name: trade_name }
        end

        output :trade
      end
    end

    contract = contract_class.new(trade_name: "HVAC")

    expect(contract.result.trade).to eq(name: "HVAC")
    expect(contract.class.graph.to_text).to include("category=lookup")
  end

  it "supports with as an alias for depends_on in compute nodes" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country, type: :string

        compute :country_code, with: :country do |country:|
          country.to_s.upcase
        end

        output :country_code
      end
    end

    contract = contract_class.new(country: "ua")

    expect(contract.result.country_code).to eq("UA")
  end

  it "supports map as a shorthand for single-dependency transforms" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :service, type: :string

        map :trade_name, from: :service do |service:|
          service.downcase == "heating" ? "HVAC" : service
        end

        output :trade_name
      end
    end

    contract = contract_class.new(service: "heating")

    expect(contract.result.trade_name).to eq("HVAC")
    expect(contract.class.graph.to_text).to include("category=map")
  end

  it "supports project for trivial hash extraction" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :payload

        project :body, from: :payload, key: :body
        project :telephony_status, from: :body, key: "telephonyStatus"

        output :telephony_status
      end
    end

    contract = contract_class.new(payload: { body: { "telephonyStatus" => "CallConnected" } })

    expect(contract.result.telephony_status).to eq("CallConnected")
    expect(contract.class.graph.to_text).to include("category=project")
  end

  it "supports aggregate nodes over incremental collections" do
    require "igniter/extensions/dataflow"

    item_contract = Class.new(Igniter::Contract) do
      define do
        input :id
        input :n, type: :numeric
        output :n
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :numbers, type: :array
        collection :items, with: :numbers, each: item_contract, key: :id, mode: :incremental
        aggregate :total, from: :items, sum: ->(item) { item.result.n.to_f }
        output :total
      end
    end

    contract = contract_class.new(numbers: [{ id: "a", n: 1 }, { id: "b", n: 2 }, { id: "c", n: 3 }])
    contract.resolve_all

    expect(contract.result.total).to eq(6.0)
    expect(contract.class.graph.to_text).to include("aggregate total")
  end

  it "supports guard nodes for explicit gating" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :open, type: :boolean

        guard :business_hours_valid, depends_on: [:open], message: "Closed" do |open:|
          open
        end

        compute :quote, depends_on: [:business_hours_valid] do |business_hours_valid:|
          business_hours_valid
          "accepted"
        end

        output :quote
      end
    end

    contract = contract_class.new(open: true)

    expect(contract.result.quote).to eq("accepted")
    expect(contract.execution.cache.fetch(:business_hours_valid).value).to eq(true)
    expect(contract.class.graph.to_text).to include("compute business_hours_valid depends_on=open callable=guard guard=true")
  end

  it "fails guard nodes with the configured message" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :open, type: :boolean

        guard :business_hours_valid, depends_on: [:open], message: "Closed" do |open:|
          open
        end

        output :business_hours_valid
      end
    end

    contract = contract_class.new(open: false)

    expect { contract.result.business_hours_valid }.to raise_error(Igniter::ResolutionError, /Closed/)
  end

  it "supports matcher-style guard eq shorthand" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country, type: :string

        map :country_code, from: :country do |country:|
          country.to_s.upcase
        end

        guard :usa_only, with: :country_code, eq: "USA", message: "Unsupported country"

        compute :shipping_zone, with: :usa_only do |usa_only:|
          usa_only
          "domestic"
        end

        output :shipping_zone
      end
    end

    contract = contract_class.new(country: "usa")

    expect(contract.result.shipping_zone).to eq("domestic")
  end

  it "fails matcher-style guard eq shorthand with the configured message" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country, type: :string

        map :country_code, from: :country do |country:|
          country.to_s.upcase
        end

        guard :usa_only, with: :country_code, eq: "USA", message: "Unsupported country"

        output :usa_only
      end
    end

    contract = contract_class.new(country: "ua")

    expect { contract.result.usa_only }.to raise_error(Igniter::ResolutionError, /Unsupported country/)
  end

  it "supports matcher-style guard in shorthand" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country_code, type: :string

        guard :supported_country, with: :country_code, in: %w[USA CAN], message: "Unsupported country"

        compute :region, with: :supported_country do |supported_country:|
          supported_country
          "north_america"
        end

        output :region
      end
    end

    contract = contract_class.new(country_code: "CAN")

    expect(contract.result.region).to eq("north_america")
  end

  it "supports matcher-style guard matches shorthand" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :zip_code, type: :string

        guard :valid_zip, with: :zip_code, matches: /\A\d{5}\z/, message: "Invalid zip"

        compute :normalized_zip, with: :valid_zip do |valid_zip:|
          valid_zip
          "ok"
        end

        output :normalized_zip
      end
    end

    contract = contract_class.new(zip_code: "60601")

    expect(contract.result.normalized_zip).to eq("ok")
  end

  it "fails matcher-style guard when no match occurs" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :zip_code, type: :string

        guard :valid_zip, with: :zip_code, matches: /\A\d{5}\z/, message: "Invalid zip"

        output :valid_zip
      end
    end

    contract = contract_class.new(zip_code: "abc")

    expect { contract.result.valid_zip }.to raise_error(Igniter::ResolutionError, /Invalid zip/)
  end

  it "supports effect as a shorthand for node success reactions" do
    observed = []

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :bid, type: :numeric
        output :bid
      end

      effect "bid" do |event:, contract:, execution:|
        observed << [event.type, event.path, contract.result.bid, execution.compiled_graph.name]
      end
    end

    contract = contract_class.new(bid: 45)

    expect(contract.result.bid).to eq(45)
    expect(observed).to eq([[:node_succeeded, "bid", 45, "AnonymousContract"]])
  end

  it "supports export as a shorthand for child output re-exports" do
    pricing_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compute :vat_rate, depends_on: [:country] do |country:|
          country == "UA" ? 0.2 : 0.0
        end

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end

        output :gross_total
        output :vat_rate
      end
    end

    checkout_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

        compose :pricing, contract: pricing_contract, inputs: {
          order_total: :order_total,
          country: :country
        }

        export :gross_total, :vat_rate, from: :pricing
      end
    end

    contract = checkout_contract.new(order_total: 100, country: "UA")

    expect(contract.result.gross_total).to eq(120.0)
    expect(contract.result.vat_rate).to eq(0.2)
  end

  it "supports expose as a shorthand for output aliases" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :service, type: :string

        map :trade_name, from: :service do |service:|
          service.downcase == "heating" ? "HVAC" : service
        end

        expose :trade_name, as: :normalized_trade_name
      end
    end

    contract = contract_class.new(service: "heating")

    expect(contract.result.normalized_trade_name).to eq("HVAC")
  end

  it "supports scope for grouped node paths" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :trade_name, type: :string

        scope :availability do
          lookup :trade, with: :trade_name do |trade_name:|
            { name: trade_name }
          end
        end

        output :trade
      end
    end

    contract = contract_class.new(trade_name: "HVAC")

    expect(contract.result.trade).to eq(name: "HVAC")
    expect(contract.class.graph.fetch_node(:trade).path).to eq("availability.trade")
    expect(contract.class.graph.to_text).to include("lookup")
    expect(contract.class.graph.to_text).to include("availability.trade")
  end

  it "supports namespace as an alias for scope" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :zip_code, type: :string

        namespace :validation do
          guard :valid_zip, with: :zip_code, matches: /\A\d{5}\z/, message: "Invalid zip"
        end

        output :valid_zip
      end
    end

    contract = contract_class.new(zip_code: "60601")

    expect(contract.result.valid_zip).to eq(true)
    expect(contract.class.graph.fetch_node(:valid_zip).path).to eq("validation.valid_zip")
  end

  it "supports collection map_inputs with extra dependencies" do
    child_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_id
        input :date
        input :property_type

        compute :summary, with: %i[technician_id date property_type] do |technician_id:, date:, property_type:|
          { technician_id: technician_id, date: date, property_type: property_type }
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_ids, type: :array
        input :date, type: :string
        input :property_type, type: :string

        collection :technicians,
          with: :technician_ids,
          depends_on: %i[date property_type],
          each: child_contract,
          key: :technician_id,
          map_inputs: lambda { |item:, date:, property_type:|
            {
              technician_id: item,
              date: date,
              property_type: property_type
            }
          }

        output :technicians
      end
    end

    contract = contract_class.new(
      technician_ids: %w[t-1 t-2],
      date: "2026-03-19",
      property_type: "commercial"
    )

    result = contract.result.technicians

    expect(result.keys).to eq(%w[t-1 t-2])
    expect(result["t-1"].result.summary).to eq(
      technician_id: "t-1",
      date: "2026-03-19",
      property_type: "commercial"
    )
    expect(contract.class.graph.to_text).to include("depends_on=technician_ids,date,property_type")
    expect(contract.class.graph.to_text).to include("mapper=#<Proc:")
  end

  it "supports using for named collection mappers" do
    child_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_id
        input :date

        compute :summary, with: %i[technician_id date] do |technician_id:, date:|
          { technician_id: technician_id, date: date }
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_ids, type: :array
        input :date, type: :string

        collection :technicians,
          with: :technician_ids,
          depends_on: :date,
          each: child_contract,
          key: :technician_id,
          using: :build_technician_inputs

        output :technicians
      end

      def build_technician_inputs(item:, date:)
        {
          technician_id: item,
          date: date
        }
      end
    end

    contract = contract_class.new(technician_ids: %w[t-1], date: "2026-03-19")

    expect(contract.result.technicians["t-1"].result.summary).to eq(
      technician_id: "t-1",
      date: "2026-03-19"
    )
  end

  it "supports using for named branch mappers" do
    us = Class.new(Igniter::Contract) do
      define do
        input :country
        input :order_total

        compute :price, with: :order_total do |order_total:|
          order_total * 1.1
        end

        output :price
      end
    end

    fallback = Class.new(Igniter::Contract) do
      define do
        input :country
        input :order_total

        expose :order_total, as: :price
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country
        input :order_total
        input :multiplier

        branch :delivery_strategy,
          with: :country,
          depends_on: %i[order_total multiplier],
          using: :build_branch_inputs do
          on "US", contract: us
          default contract: fallback
        end

        export :price, from: :delivery_strategy
      end

      def build_branch_inputs(selector:, order_total:, multiplier:)
        {
          country: selector,
          order_total: order_total * multiplier
        }
      end
    end

    contract = contract_class.new(country: "US", order_total: 100, multiplier: 2)

    expect(contract.result.price).to be_within(0.001).of(220.0)
  end
end
