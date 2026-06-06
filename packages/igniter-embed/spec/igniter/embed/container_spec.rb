# frozen_string_literal: true

require_relative "../../spec_helper"
require "securerandom"
require "tmpdir"

RSpec.describe Igniter::Embed::Container do
  before do
    stub_const("Billing", Module.new)
    stub_const("Billing::PriceContract", Class.new(Igniter::Contract) do
      define do
        input :amount
        compute :total, depends_on: [:amount] do |amount:|
          amount * 1.2
        end
        output :total
      end
    end)
  end

  it "runs two named contracts in one container" do
    contracts = Igniter::Embed.configure(:billing)

    contracts.register(:tax_quote) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    contracts.register(:discount_quote) do
      input :amount
      compute :discount, depends_on: [:amount] do |amount:|
        amount * 0.1
      end
      output :discount
    end

    tax_result = contracts.call(:tax_quote, amount: 100)
    discount_result = contracts.call(:discount_quote, amount: 100)

    expect(tax_result).to be_success
    expect(tax_result.output(:tax)).to eq(20.0)
    expect(discount_result).to be_success
    expect(discount_result.output(:discount)).to eq(10.0)
  end

  it "runs block and class contracts in one container" do
    contracts = Igniter::Embed.configure(:billing)
    contracts.register(:tax_quote) do
      input :amount
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :tax
    end
    contracts.register(:price_quote, Billing::PriceContract)

    expect(contracts.call(:tax_quote, amount: 100).output(:tax)).to eq(20.0)
    expect(contracts.call(:price_quote, amount: 100).output(:total)).to eq(120.0)
    expect(contracts.registry.to_h.fetch(:price_quote)).to include(kind: :class)
  end

  it "registers contract classes from host configuration" do
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.contract Billing::PriceContract, as: :price_quote
    end

    expect(contracts.call(:price_quote, amount: 100).output(:total)).to eq(120.0)
    expect(contracts.registry.to_h.fetch(:price_quote)).to include(kind: :class)
  end

  it "uses config.root only when opt-in discovery is enabled" do
    Dir.mktmpdir("igniter-embed-contracts") do |root|
      File.write(File.join(root, "price_contract.rb"), <<~RUBY)
        class IgnoredByDefaultContract < Igniter::Contract
          define do
            input :amount
            output :amount
          end
        end
      RUBY

      contracts = Igniter::Embed.configure(:billing) do |config|
        config.root root
      end

      expect(contracts.registry.names).to eq([])
    end
  end

  it "discovers contract classes from config.root when discovery is enabled" do
    namespace = "EmbedDiscovery#{SecureRandom.hex(4)}"

    Dir.mktmpdir("igniter-embed-contracts") do |root|
      File.write(File.join(root, "price_contract.rb"), <<~RUBY)
        module #{namespace}
          class PriceContract < Igniter::Contract
            define do
              input :amount
              compute :total, depends_on: [:amount] do |amount:|
                amount * 1.2
              end
              output :total
            end
          end
        end
      RUBY

      contracts = Igniter::Embed.configure(:billing) do |config|
        config.root root
        config.discover!
      end

      expect(contracts.registry.names).to include(:price)
      expect(contracts.call(:price, amount: 100).output(:total)).to eq(120.0)
    end
  end

  it "ignores anonymous contract classes during discovery" do
    Dir.mktmpdir("igniter-embed-contracts") do |root|
      File.write(File.join(root, "anonymous_contract.rb"), <<~RUBY)
        Class.new(Igniter::Contract) do
          define do
            input :amount
            output :amount
          end
        end
      RUBY

      contracts = Igniter::Embed.configure(:billing) do |config|
        config.root root
        config.discover!
      end

      expect(contracts.registry.names).to eq([])
    end
  end

  it "lets explicit registrations win over discovered contracts with the same inferred name" do
    namespace = "EmbedDiscoveryExplicit#{SecureRandom.hex(4)}"

    Dir.mktmpdir("igniter-embed-contracts") do |root|
      File.write(File.join(root, "price_contract.rb"), <<~RUBY)
        module #{namespace}
          class PriceContract < Igniter::Contract
            define do
              input :amount
              compute :total, depends_on: [:amount] do |amount:|
                amount * 9
              end
              output :total
            end
          end
        end
      RUBY

      contracts = Igniter::Embed.configure(:billing) do |config|
        config.root root
        config.contract Billing::PriceContract, as: :price
        config.discover!
      end

      expect(contracts.call(:price, amount: 100).output(:total)).to eq(120.0)
      expect(contracts.registry.names).to eq([:price])
    end
  end

  it "raises a clear error for duplicate discovered inferred names" do
    namespace = "EmbedDiscoveryDuplicate#{SecureRandom.hex(4)}"

    Dir.mktmpdir("igniter-embed-contracts") do |root|
      File.write(File.join(root, "first_price_contract.rb"), <<~RUBY)
        module #{namespace}
          module First
            class PriceContract < Igniter::Contract
              define do
                input :amount
                output :amount
              end
            end
          end
        end
      RUBY
      File.write(File.join(root, "second_price_contract.rb"), <<~RUBY)
        module #{namespace}
          module Second
            class PriceContract < Igniter::Contract
              define do
                input :amount
                output :amount
              end
            end
          end
        end
      RUBY

      expect do
        Igniter::Embed.configure(:billing) do |config|
          config.root root
          config.discover!
        end
      end.to raise_error(Igniter::Embed::DiscoveryError, /duplicate contract names :price/)
    end
  end

  it "raises a clear error when discovery is enabled without a root" do
    expect do
      Igniter::Embed.configure(:billing, &:discover!)
    end.to raise_error(Igniter::Embed::DiscoveryError, /config.root/)
  end

  it "infers class contract names when registering a named contract class" do
    contracts = Igniter::Embed.configure(:billing)

    handle = contracts.register(Billing::PriceContract)

    expect(handle.name).to eq(:price)
    expect(contracts.call(:price, amount: 100).output(:total)).to eq(120.0)
  end

  it "requires explicit names for anonymous class contracts" do
    anonymous_contract = Class.new(Igniter::Contract) do
      define do
        input :amount
        output :amount
      end
    end
    contracts = Igniter::Embed.configure(:billing)

    expect do
      contracts.register(anonymous_contract)
    end.to raise_error(Igniter::Embed::InvalidContractRegistrationError, /anonymous/)
  end

  it "compiles lazily and caches registered contracts when cache is enabled" do
    compile_count = 0
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.cache = true
    end

    contracts.register(:quote) do
      compile_count += 1
      input :amount
      output :amount
    end

    expect(compile_count).to eq(0)

    expect(contracts.call(:quote, amount: 1).output(:amount)).to eq(1)
    expect(contracts.call(:quote, amount: 2).output(:amount)).to eq(2)
    expect(compile_count).to eq(1)
  end

  it "can disable the compiled graph cache" do
    compile_count = 0
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.cache = false
    end

    contracts.register(:quote) do
      compile_count += 1
      input :amount
      output :amount
    end

    contracts.call(:quote, amount: 1)
    contracts.call(:quote, amount: 2)

    expect(compile_count).to eq(2)
  end

  it "returns failure envelopes for captured contract exceptions" do
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.capture_exceptions = true
    end

    contracts.register(:broken) do
      input :amount
      compute :quote, depends_on: [:amount] do |amount:|
        raise "boom" if amount
      end
      output :quote
    end

    result = contracts.call(:broken, amount: 10)

    expect(result).to be_failure
    expect(result.errors.first.message).to eq("boom")
    expect(result.to_h[:metadata]).to eq(captured_exception: true)
  end

  it "returns failure envelopes for captured class contract exceptions" do
    broken_contract = Class.new(Igniter::Contract) do
      define do
        input :amount
        compute :quote, depends_on: [:amount] do |amount:|
          raise "boom" if amount
        end
        output :quote
      end
    end
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.capture_exceptions = true
    end
    contracts.register(:broken, broken_contract)

    result = contracts.call(:broken, amount: 10)

    expect(result).to be_failure
    expect(result.errors.first.message).to eq("boom")
    expect(result.to_h[:metadata]).to eq(captured_exception: true)
  end
end
