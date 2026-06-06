# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts extension layering" do
  it "locates experimental packs under Assembly" do
    expect(Igniter::Contracts::Assembly::ConstPack).to equal(Igniter::Contracts::ConstPack)
    expect(Igniter::Contracts::Assembly::ProjectPack).to equal(Igniter::Contracts::ProjectPack)
    expect(Igniter::Contracts::Assembly::StepResultPack).to equal(Igniter::Contracts::StepResultPack)
  end

  it "locates extension execution helpers under Execution when the pack extends runtime semantics" do
    expect(Igniter::Contracts::Execution::ConstRuntime).to equal(Igniter::Contracts::ConstRuntime)
    expect(Igniter::Contracts::Execution::StepResult).to equal(Igniter::Contracts::StepResult)
  end
end
