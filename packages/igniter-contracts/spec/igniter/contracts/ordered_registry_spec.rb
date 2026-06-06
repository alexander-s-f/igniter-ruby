# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::OrderedRegistry do
  it "preserves registration order" do
    registry = described_class.new(name: :validators)

    registry.register(:one, :first_validator)
    registry.register(:two, :second_validator)

    expect(registry.entries.map(&:key)).to eq(%i[one two])
    expect(registry.entries.map(&:value)).to eq(%i[first_validator second_validator])
  end

  it "rejects duplicate keys" do
    registry = described_class.new(name: :validators)
    registry.register(:one, :first_validator)

    expect { registry.register(:one, :second_validator) }
      .to raise_error(Igniter::Contracts::DuplicateRegistrationError, /validators already has one/)
  end

  it "rejects writes after freezing" do
    registry = described_class.new(name: :validators)
    registry.freeze!

    expect { registry.register(:one, :validator) }
      .to raise_error(Igniter::Contracts::FrozenRegistryError, /validators is frozen/)
  end
end
