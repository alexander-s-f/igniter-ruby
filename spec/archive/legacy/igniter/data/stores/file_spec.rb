# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "igniter/sdk/data"

RSpec.describe Igniter::Data::Stores::File do
  it "stores and retrieves JSON values across instances" do
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "data.json")
      store = described_class.new(path: path)

      store.put(
        collection: :telegram_bindings,
        key: :chat_123,
        value: { "chat_id" => "123", "username" => "alex" }
      )

      reloaded = described_class.new(path: path)
      expect(reloaded.get(collection: :telegram_bindings, key: :chat_123)).to eq(
        "chat_id" => "123",
        "username" => "alex"
      )
    end
  end

  it "lists, deletes, and clears collection data" do
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "data.json")
      store = described_class.new(path: path)

      store.put(collection: :notes, key: :a, value: "one")
      store.put(collection: :notes, key: :b, value: { "n" => 2 })

      expect(store.keys(collection: :notes)).to eq(%w[a b])
      expect(store.all(collection: :notes)).to eq(
        "a" => "one",
        "b" => { "n" => 2 }
      )

      expect(store.delete(collection: :notes, key: :a)).to eq("one")
      expect(store.get(collection: :notes, key: :a)).to be_nil

      store.clear(collection: :notes)
      expect(store.all(collection: :notes)).to eq({})
    end
  end
end
