# frozen_string_literal: true

require "spec_helper"
require "igniter/sdk/data"

RSpec.describe Igniter::Data::Stores::SQLite do
  subject(:store) { described_class.new(path: ":memory:") }

  it "stores and retrieves JSON values" do
    store.put(
      collection: :telegram_bindings,
      key: :chat_123,
      value: { "chat_id" => "123", "username" => "alex" }
    )

    expect(store.get(collection: :telegram_bindings, key: :chat_123)).to eq(
      "chat_id" => "123",
      "username" => "alex"
    )
  end

  it "lists all keys and values for a collection" do
    store.put(collection: :notes, key: :a, value: "one")
    store.put(collection: :notes, key: :b, value: { "n" => 2 })

    expect(store.keys(collection: :notes)).to eq(%w[a b])
    expect(store.all(collection: :notes)).to eq(
      "a" => "one",
      "b" => { "n" => 2 }
    )
  end

  it "deletes one key and can clear an entire collection" do
    store.put(collection: :notes, key: :a, value: "one")
    store.put(collection: :notes, key: :b, value: "two")

    expect(store.delete(collection: :notes, key: :a)).to eq("one")
    expect(store.get(collection: :notes, key: :a)).to be_nil

    store.clear(collection: :notes)
    expect(store.all(collection: :notes)).to eq({})
  end
end
