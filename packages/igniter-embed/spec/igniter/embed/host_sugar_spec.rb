# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Embed.host sugar" do
  before do
    billing = Module.new do
      def self.root
        "/tmp/billing"
      end
    end
    stub_const("Billing", billing)
    stub_const("Billing::PriceQuoteContract", Class.new(Igniter::Contract) do
      define do
        input :amount
        compute :total, depends_on: [:amount] do |amount:|
          amount * 1.2
        end
        output :total
      end
    end)
    stub_const("Billing::LegacyQuoteService", Class.new)
    stub_const("Billing::ContractQuoteService", Class.new)
    stub_const("Billing::QuoteObserver", Class.new)
    stub_const("Billing::QuoteNormalizer", Class.new)
    stub_const("Billing::ObservationStore", Class.new)
    stub_const("Billing::LogObservationContract", Class.new(Igniter::Contract) do
      define do
        input :event
        output :event
      end
    end)
  end

  it "builds the same plain contract registration as the clean form" do
    clean = Igniter::Embed.configure(:billing) do |config|
      config.owner Billing
      config.root Billing.root
      config.cache = false
      config.contract Billing::PriceQuoteContract, as: :price_quote
    end

    sugar = Igniter::Embed.host(:billing) do
      owner Billing
      path "."
      cache false

      contracts do
        add :price_quote, Billing::PriceQuoteContract
      end
    end

    expect(sugar.config.name).to eq(clean.config.name)
    expect(sugar.config.owner).to eq(clean.config.owner)
    expect(sugar.config.root).to eq(clean.config.root)
    expect(sugar.config.cache?).to eq(clean.config.cache?)
    expect(sugar.registry.to_h).to eq(clean.registry.to_h)
    expect(sugar.call(:price_quote, amount: 100).output(:total)).to eq(120.0)
  end

  it "infers contract names the same way container registration does" do
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add Billing::PriceQuoteContract
      end
    end

    expect(contracts.registry.names).to eq([:price_quote])
    expect(contracts.call(:price_quote, amount: 100).output(:total)).to eq(120.0)
  end

  it "supports the explicit config.contracts form as the same first slice" do
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.owner Billing
      config.path "."
      config.contracts do
        add :price_quote, Billing::PriceQuoteContract
      end
    end

    expect(contracts.config.root).to eq("/tmp/billing")
    expect(contracts.registry.names).to eq([:price_quote])
  end

  it "exposes structured sugar expansion output" do
    contracts = Igniter::Embed.host(:billing) do
      owner Billing
      path "app/contracts"
      cache false

      contracts do
        add Billing::PriceQuoteContract
      end
    end

    expect(contracts.sugar_expansion.to_h).to include(
      host: :billing,
      owner: "Billing",
      root: "/tmp/billing/app/contracts",
      cache: false,
      contractables: [],
      capabilities: [],
      events: []
    )
    expect(contracts.sugar_expansion.to_h.fetch(:contracts)).to eq(
      [
        {
          name: :price_quote,
          class: "Billing::PriceQuoteContract",
          kind: :class
        }
      ]
    )
  end

  it "includes generated migration contractables in sugar expansion output" do
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
          migration from: Billing::LegacyQuoteService,
                    to: Billing::ContractQuoteService
          shadow async: false, sample: 0.25
        end
      end
    end

    expect(contracts.config.contractable_configs.length).to eq(1)
    expect(contracts.sugar_expansion.to_h.fetch(:contractables)).to match(
      [
        include(
          name: :price_quote,
          role: :migration_candidate,
          stage: :shadowed,
          primary: "Billing::LegacyQuoteService",
          candidate: "Billing::ContractQuoteService",
          async: false,
          sample: 0.25,
          metadata: {},
          adapters: {
            redaction: a_string_matching(/Proc/),
            acceptance: { policy: :exact, options: {} }
          },
          runner: {
            accessor: "contractable(:price_quote)",
            materializable: true
          }
        )
      ]
    )
  end

  it "materializes generated contractable runners from the host" do
    store = Class.new do
      attr_reader :observations

      def initialize
        @observations = []
      end

      def record(observation)
        observations << observation
      end
    end.new
    normalizer = lambda do |result|
      {
        status: :ok,
        outputs: result,
        metadata: {}
      }
    end
    primary = ->(amount:) { { total: amount * 1.2 } }
    candidate = ->(amount:) { { total: amount * 1.2 } }
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
          migrate primary, to: candidate
          shadow async: false
          use :normalizer, normalizer
          use :store, store
        end
      end
    end
    clean_runner = Igniter::Embed.contractable(:price_quote) do |config|
      config.primary primary
      config.candidate candidate
      config.async false
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.store store
    end

    runner = contracts.contractable(:price_quote)

    expect(contracts.contractable_names).to eq([:price_quote])
    expect(contracts.contractable(:price_quote)).to equal(runner)
    expect(runner.config.role).to eq(clean_runner.config.role)
    expect(runner.config.stage).to eq(:shadowed)
    expect(runner.call(amount: 100)).to eq(total: 120.0)
    expect(store.observations.last).to include(name: :price_quote, match: true)
  end

  it "raises a clear error for unknown generated contractables" do
    contracts = Igniter::Embed.host(:billing)

    expect do
      contracts.contractable(:missing)
    end.to raise_error(Igniter::Embed::UnknownContractableError, /unknown contractable missing/)
  end

  it "includes visible host-boundary adapters in sugar expansion output" do
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
          migration from: Billing::LegacyQuoteService,
                    to: Billing::ContractQuoteService
          use :normalizer, Billing::QuoteNormalizer
          use :redaction, only: %i[account_id quote_id]
          use :acceptance, policy: :completed
          use :store, Billing::ObservationStore
        end
      end
    end

    expect(contracts.sugar_expansion.to_h.fetch(:contractables).first.fetch(:adapters)).to include(
      normalizer: "Billing::QuoteNormalizer",
      redaction: a_string_matching(/Proc/),
      acceptance: { policy: :completed, options: {} },
      store: "Billing::ObservationStore"
    )
  end

  it "includes typed event hooks in sugar expansion output" do
    failure_handler = ->(_event) {}
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
          migration from: Billing::LegacyQuoteService,
                    to: Billing::ContractQuoteService
          use :normalizer, Billing::QuoteNormalizer
          on :failure, failure_handler
        end
      end
    end

    expect(contracts.sugar_expansion.to_h.fetch(:contractables).first.fetch(:events)).to contain_exactly(
      include(event: :primary_error, source: :failure, handler: a_string_matching(/Proc/)),
      include(event: :candidate_error, source: :failure, handler: a_string_matching(/Proc/)),
      include(event: :acceptance_failure, source: :failure, handler: a_string_matching(/Proc/)),
      include(event: :store_error, source: :failure, handler: a_string_matching(/Proc/))
    )
  end

  it "attaches explicit capability targets and exposes their kind" do
    report_adapter = ->(_event) {}
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
          migration from: Billing::LegacyQuoteService,
                    to: Billing::ContractQuoteService
          use :normalizer, Billing::QuoteNormalizer
          use :logging, contract: Billing::LogObservationContract
          use :reporting, report_adapter
        end
      end
    end

    contractable_config = contracts.config.contractable_config(:price_quote)
    expect(contractable_config.capability_attachments.map(&:name)).to eq(%i[logging reporting])
    expect(contracts.sugar_expansion.to_h.fetch(:contractables).first.fetch(:capabilities)).to contain_exactly(
      {
        name: :logging,
        kind: :contract,
        target: "Billing::LogObservationContract"
      },
      {
        name: :reporting,
        kind: :callable_adapter,
        target: a_string_matching(/Proc/)
      }
    )
  end

  it "requires explicit targets for broad capability sugar" do
    expect do
      Igniter::Embed.host(:billing) do
        contracts do
          add :price_quote, Billing::PriceQuoteContract do
            migration from: Billing::LegacyQuoteService,
                      to: Billing::ContractQuoteService
            use :metrics
          end
        end
      end
    end.to raise_error(Igniter::Embed::SugarError, /requires an explicit target/)
  end

  it "rejects duplicate capability attachments" do
    adapter = ->(_event) {}

    expect do
      Igniter::Embed.host(:billing) do
        contracts do
          add :price_quote, Billing::PriceQuoteContract do
            migration from: Billing::LegacyQuoteService,
                      to: Billing::ContractQuoteService
            use :validation, adapter
            use :validation, adapter
          end
        end
      end
    end.to raise_error(Igniter::Embed::SugarError, /capability :validation is already configured/)
  end

  it "does not generate a contractable for an empty add block" do
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :price_quote, Billing::PriceQuoteContract do
        end
      end
    end

    expect(contracts.registry.names).to eq([:price_quote])
    expect(contracts.config.contractable_configs).to eq([])
    expect(contracts.sugar_expansion.to_h.fetch(:contractables)).to eq([])
  end

  it "includes generated observed and discovery contractables in sugar expansion output" do
    contracts = Igniter::Embed.host(:billing) do
      contracts do
        add :quote_observer, Billing::PriceQuoteContract do
          observe Billing::QuoteObserver
        end

        add :quote_probe, Billing::PriceQuoteContract do
          discover Billing::LegacyQuoteService
          capture calls: true, timing: true, errors: true
        end
      end
    end

    expect(contracts.sugar_expansion.to_h.fetch(:contractables)).to contain_exactly(
      include(
        name: :quote_observer,
        role: :observed_service,
        stage: :captured,
        primary: "Billing::QuoteObserver",
        candidate: nil,
        adapters: include(acceptance: { policy: :exact, options: {} })
      ),
      include(
        name: :quote_probe,
        role: :discovery_probe,
        stage: :profiled,
        primary: "Billing::LegacyQuoteService",
        candidate: nil,
        metadata: { capture: { calls: true, timing: true, errors: true } },
        adapters: include(acceptance: { policy: :exact, options: {} })
      )
    )
  end

  it "raises the same anonymous contract error as clean registration" do
    anonymous_contract = Class.new(Igniter::Contract) do
      define do
        input :amount
        output :amount
      end
    end

    expect do
      Igniter::Embed.host(:billing) do
        contracts do
          add anonymous_contract
        end
      end
    end.to raise_error(Igniter::Embed::InvalidContractRegistrationError, /anonymous/)
  end

  it "rejects ambiguous path arrays in the first implementation slice" do
    expect do
      Igniter::Embed.host(:billing) do
        path ["app/contracts", "engines/billing/app/contracts"]
      end
    end.to raise_error(Igniter::Embed::SugarError, /exactly one path/)
  end
end
