# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::AI::Client do
  it "runs a request through a fake provider" do
    client = described_class.new(provider: Igniter::AI::Providers::Fake.new(text: "Ready."))

    response = client.complete(model: "fake", input: "state")

    expect(response).to be_success
    expect(response.text).to eq("Ready.")
    expect(response.metadata).to include(provider: :fake, model: "fake")
  end

  it "replays recorded responses without network access" do
    provider = Igniter::AI::Providers::Recorded.new(
      records: [
        { text: "First.", usage: { input_tokens: 2, output_tokens: 1 }, metadata: { fixture: :daily } }
      ]
    )

    response = described_class.new(provider: provider).complete(model: "recorded", input: "state")
    exhausted = described_class.new(provider: provider).complete(model: "recorded", input: "state")

    expect(response.text).to eq("First.")
    expect(response.usage.input_tokens).to eq(2)
    expect(response.metadata).to include(provider: :recorded, fixture: :daily)
    expect(exhausted.error).to eq(:recording_exhausted)
  end
end
