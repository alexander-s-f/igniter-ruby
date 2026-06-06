# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::ExecutionRequest do
  it "wraps compiled graph, typed inputs, profile, and runtime" do
    profile = Igniter::Contracts.default_profile
    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      output :amount
    end

    request = described_class.new(
      compiled_graph: compiled,
      inputs: { amount: 10 },
      profile: profile,
      runtime: Igniter::Contracts::Runtime
    )

    expect(request.compiled_graph).to equal(compiled)
    expect(request.inputs).to be_a(Igniter::Contracts::NamedValues)
    expect(request.inputs.fetch(:amount)).to eq(10)
    expect(request.profile).to equal(profile)
    expect(request.runtime).to equal(Igniter::Contracts::Runtime)
    expect(request).to be_frozen
  end
end
