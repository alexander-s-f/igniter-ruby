# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Registry do
  it "registers and fetches entries by symbolized key" do
    registry = described_class.new(name: :nodes)

    registry.register("input", :input_node)

    expect(registry.fetch(:input)).to eq(:input_node)
    expect(registry.registered?(:input)).to be(true)
  end

  it "rejects duplicate keys" do
    registry = described_class.new(name: :nodes)
    registry.register(:input, :first)

    expect { registry.register(:input, :second) }
      .to raise_error(Igniter::Contracts::DuplicateRegistrationError, /nodes already has input/)
  end

  it "rejects writes after freezing" do
    registry = described_class.new(name: :nodes)
    registry.freeze!

    expect { registry.register(:input, :input_node) }
      .to raise_error(Igniter::Contracts::FrozenRegistryError, /nodes is frozen/)
  end
end
