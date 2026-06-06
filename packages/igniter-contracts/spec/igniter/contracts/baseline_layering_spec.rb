# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts baseline layering" do
  it "locates baseline pack assembly concerns under Assembly" do
    expect(Igniter::Contracts::Assembly::BaselinePack).to equal(Igniter::Contracts::BaselinePack)
  end

  it "locates baseline execution concerns under Execution" do
    expect(Igniter::Contracts::Execution::BaselineNormalizers).to equal(Igniter::Contracts::BaselineNormalizers)
    expect(Igniter::Contracts::Execution::BaselineValidators).to equal(Igniter::Contracts::BaselineValidators)
    expect(Igniter::Contracts::Execution::BaselineRuntime).to equal(Igniter::Contracts::BaselineRuntime)
  end
end
