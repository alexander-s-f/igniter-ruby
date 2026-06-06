# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::EffectInvocation do
  it "wraps payload, profile, and typed context" do
    profile = Igniter::Contracts.default_profile
    invocation = described_class.new(
      payload: { amount: 10 },
      context: { source: :spec },
      profile: profile
    )

    expect(invocation.payload).to eq({ amount: 10 })
    expect(invocation.context).to be_a(Igniter::Contracts::NamedValues)
    expect(invocation.context.fetch(:source)).to eq(:spec)
    expect(invocation.profile).to equal(profile)
    expect(invocation).to be_frozen
  end
end
