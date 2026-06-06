# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "igniter/sdk/data"

RSpec.describe Igniter::Cluster::ProjectionStore do
  let(:store) { Igniter::Data::Stores::InMemory.new }
  subject(:projection_store) { described_class.new(store: store, collection: "test_projections") }

  it "projects records with a projection timestamp" do
    entry = projection_store.project("id" => "voice-1", "state" => "responded")

    expect(entry).to include(
      "id" => "voice-1",
      "state" => "responded"
    )
    expect(entry["projection_updated_at"]).to be_a(String)
    expect(projection_store.get("voice-1")).to eq(entry)
  end

  it "merges metadata into the projection" do
    entry = projection_store.project(
      { "id" => "voice-1", "state" => "responded" },
      metadata: { "ownership" => { "owner" => "edge" } }
    )

    expect(entry.dig("ownership", "owner")).to eq("edge")
  end

  it "supports custom primary keys and explicit keys" do
    custom_store = described_class.new(
      store: store,
      collection: "custom_projections",
      primary_key: "slug"
    )

    custom = custom_store.project("slug" => "daily-checkin", "title" => "Daily Check-in")
    explicit = custom_store.project({ "title" => "Fallback" }, key: "manual-id")

    expect(custom_store.get("daily-checkin")).to eq(custom)
    expect(custom_store.get("manual-id")).to eq(explicit)
    expect(explicit["slug"]).to eq("manual-id")
  end

  it "raises when no key can be resolved" do
    expect {
      projection_store.project("state" => "responded")
    }.to raise_error(ArgumentError, /missing primary key/)
  end

  it "lists and clears projected entries" do
    projection_store.project("id" => "a", "state" => "captured")
    projection_store.project("id" => "b", "state" => "responded")

    expect(projection_store.all.map { |entry| entry["id"] }).to contain_exactly("a", "b")

    projection_store.clear

    expect(projection_store.all).to eq([])
  end
end
