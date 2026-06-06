# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::AI::Providers::OpenAIResponses do
  it "normalizes successful Responses API payloads" do
    provider = described_class.new(
      api_key: "sk-test",
      model: "gpt-test",
      transport: lambda do |payload|
        expect(payload).to include(
          model: "gpt-test",
          store: false,
          instructions: "Be concise.",
          input: "Two reminders."
        )
        [
          200,
          JSON.generate(
            "id" => "resp_1",
            "output_text" => "Close one reminder.",
            "usage" => {
              "input_tokens" => 10,
              "output_tokens" => 4,
              "total_tokens" => 14
            }
          )
        ]
      end
    )

    response = provider.complete(
      Igniter::AI.request(model: "ignored", instructions: "Be concise.", input: "Two reminders.")
    )

    expect(response).to be_success
    expect(response.text).to eq("Close one reminder.")
    expect(response.usage.total_tokens).to eq(14)
    expect(response.metadata).to include(provider: :openai, model: "gpt-test", id: "resp_1")
  end

  it "returns structured failures for provider HTTP errors" do
    provider = described_class.new(
      api_key: "sk-test",
      model: "gpt-test",
      transport: ->(_payload) { [429, JSON.generate("error" => "rate limited")] }
    )

    response = provider.complete(Igniter::AI.request(model: "ignored", input: "state"))

    expect(response).not_to be_success
    expect(response.error).to eq("openai_http_429")
    expect(response.metadata).to include(provider: :openai, status: 429)
  end
end
