# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-agents/lib/igniter-agents"

RSpec.describe "igniter-agents local gem facade" do
  it "re-exports the actor runtime and built-in agent packs from the local package" do
    expect(Igniter::Agent).to be_a(Class)
    expect(Igniter::Supervisor::RestartBudgetExceeded.superclass).to eq(Igniter::Error)
    expect(Igniter::Registry).to be_a(Module)
    expect(Igniter::Agents).to be_a(Module)
    expect(Igniter::AI::Agents).to be_a(Module)
  end
end
