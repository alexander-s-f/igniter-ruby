# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/data"

RSpec.describe Igniter::Data do
  after do
    Igniter::Data.reset!
  end

  it "defaults to an in-memory store" do
    expect(described_class.default_store).to be_a(Igniter::Data::Stores::InMemory)
  end

  it "allows overriding the default store" do
    custom_store = Igniter::Data::Stores::InMemory.new

    described_class.configure do |data|
      data.default_store = custom_store
    end

    expect(described_class.default_store).to be(custom_store)
  end

  describe Igniter::Data::Stores::InMemory do
    subject(:store) { described_class.new }

    it "stores and retrieves values by collection and key" do
      store.put(collection: :notes, key: :favorite_language, value: { "value" => "Ruby" })

      expect(store.get(collection: :notes, key: :favorite_language)).to eq("value" => "Ruby")
    end

    it "lists all values in a collection" do
      store.put(collection: :notes, key: :x, value: 1)
      store.put(collection: :notes, key: :y, value: 2)

      expect(store.all(collection: :notes)).to eq("x" => 1, "y" => 2)
      expect(store.keys(collection: :notes)).to eq(%w[x y])
    end

    it "deletes entries and clears collections" do
      store.put(collection: :notes, key: :x, value: 1)
      store.put(collection: :sessions, key: :abc, value: { "turns" => 3 })

      expect(store.delete(collection: :notes, key: :x)).to eq(1)
      expect(store.get(collection: :notes, key: :x)).to be_nil

      store.clear(collection: :sessions)
      expect(store.all(collection: :sessions)).to eq({})
    end
  end
end
