# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::AgentSessionStore do
  let(:session) do
    Igniter::Runtime::AgentSession.new(
      token: "remote-session",
      node_name: :approval,
      agent_name: :reviewer,
      message_name: :review,
      mode: :call,
      reply_mode: :deferred,
      ownership: :remote,
      owner_url: "http://seed:4567",
      delivery_route: { routing_mode: :static, url: "http://seed:4567", remote: true },
      payload: { requested_name: "Alice" }
    )
  end

  it "persists sessions through the configured runtime store" do
    store = Igniter::Runtime::Stores::MemoryStore.new
    first = described_class.new(store: store)
    second = described_class.new(store: store)

    first.save(session)

    expect(second.exist?("remote-session")).to be(true)
    restored = second.fetch("remote-session")
    expect(restored).to have_attributes(
      token: "remote-session",
      ownership: :remote,
      owner_url: "http://seed:4567"
    )
    expect(restored.payload).to eq(requested_name: "Alice")
    expect(second.list_tokens).to include("remote-session")

    second.delete("remote-session")
    expect(first.exist?("remote-session")).to be(false)
  end

  it "falls back to in-memory storage when no runtime store is configured" do
    session_store = described_class.new

    session_store.save(session)

    expect(session_store.fetch("remote-session").payload).to eq(requested_name: "Alice")
    expect(session_store.list_tokens).to include("remote-session")
  end
end
