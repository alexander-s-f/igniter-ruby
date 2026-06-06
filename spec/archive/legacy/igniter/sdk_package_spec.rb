# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-sdk/lib/igniter-sdk"

RSpec.describe "igniter-sdk local gem facade" do
  it "re-exports the sdk registry and optional packs from the local package" do
    expect(Igniter::SDK.fetch(:ai).entrypoint).to eq("igniter/ai")
    expect(Igniter::SDK.fetch(:agents).entrypoint).to eq("igniter/agents")
    expect(Igniter::SDK.fetch(:channels).entrypoint).to eq("igniter/sdk/channels")
    expect(Igniter::SDK.fetch(:data).entrypoint).to eq("igniter/sdk/data")
    expect(Igniter::SDK.fetch(:tools).entrypoint).to eq("igniter/sdk/tools")
  end
end
