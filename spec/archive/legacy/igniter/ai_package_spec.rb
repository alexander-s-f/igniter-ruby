# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-ai/lib/igniter-ai"

RSpec.describe "igniter-ai local gem facade" do
  it "re-exports the AI runtime from the local package" do
    expect(Igniter::AI).to be_a(Module)
    expect(Igniter::AI::Config).to be_a(Class)
    expect(Igniter::AI::Executor).to be_a(Class)
    expect(Igniter::AI::ToolRegistry).to be_a(Module)
  end
end
