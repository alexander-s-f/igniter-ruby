# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::Registry do
  subject(:registry) { described_class.new }

  let(:contract_class) do
    Class.new(Igniter::Contract) do
      define do
        input :x
        output :x
      end
    end
  end

  describe "#register / #fetch" do
    it "registers and retrieves a contract by name" do
      registry.register("MyContract", contract_class)
      expect(registry.fetch("MyContract")).to eq(contract_class)
    end

    it "retrieves by string name regardless of how it was registered" do
      registry.register("MyContract", contract_class)
      expect(registry.fetch("MyContract")).to eq(contract_class)
    end

    it "raises RegistryError when fetching an unregistered contract" do
      expect { registry.fetch("Missing") }
        .to raise_error(Igniter::Server::Registry::RegistryError, /not registered/)
    end

    it "raises when registering a non-Contract class" do
      expect { registry.register("Bad", String) }
        .to raise_error(Igniter::Server::Registry::RegistryError, /Igniter::Contract subclass/)
    end
  end

  describe "#names" do
    it "returns all registered names" do
      registry.register("A", contract_class)
      registry.register("B", contract_class)
      expect(registry.names).to contain_exactly("A", "B")
    end
  end

  describe "#registered?" do
    it "returns true for registered contracts" do
      registry.register("A", contract_class)
      expect(registry.registered?("A")).to be true
    end

    it "returns false for unregistered contracts" do
      expect(registry.registered?("Missing")).to be false
    end
  end

  describe "#introspect" do
    it "returns metadata for each registered contract" do
      registry.register("MyContract", contract_class)
      info = registry.introspect.find { |i| i[:name] == "MyContract" }
      expect(info[:inputs]).to include(:x)
      expect(info[:outputs]).to include(:x)
    end
  end
end
