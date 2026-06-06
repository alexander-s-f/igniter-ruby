# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter application AI wiring" do
  around do |example|
    original = ENV.fetch("IGNITER_TEST_OPENAI_API_KEY", nil)
    ENV["IGNITER_TEST_OPENAI_API_KEY"] = "sk-test-secret"
    example.run
  ensure
    if original.nil?
      ENV.delete("IGNITER_TEST_OPENAI_API_KEY")
    else
      ENV["IGNITER_TEST_OPENAI_API_KEY"] = original
    end
  end

  it "builds AI clients from application-level provider declarations" do
    kernel = Igniter::Application.build_kernel
    kernel.ai do
      provider :summary, :fake, text: "Daily summary."
    end
    environment = Igniter::Application::Environment.new(profile: kernel.finalize)

    response = environment.ai_client(:summary).complete(model: "fake", input: "state")

    expect(response).to be_success
    expect(response.text).to eq("Daily summary.")
    expect(environment.ai_provider_names).to eq([:summary])
    expect(environment.profile.to_h.fetch(:ai)).to include(
      include(name: :summary, adapter: :fake, mode: :live)
    )
  end

  it "keeps provider credentials redacted in profile data" do
    kernel = Igniter::Application.build_kernel.credential(
      :openai_api_key,
      env: "IGNITER_TEST_OPENAI_API_KEY"
    )
    kernel.ai do
      provider :openai, credential: :openai_api_key, model: "gpt-test"
    end
    environment = Igniter::Application::Environment.new(profile: kernel.finalize)

    payload = environment.profile.to_h

    expect(environment.credentials.fetch(:openai_api_key)).to eq("sk-test-secret")
    expect(payload.to_s).not_to include("sk-test-secret")
    expect(payload.fetch(:ai)).to include(
      include(name: :openai, adapter: :openai, credential: :openai_api_key, model: "gpt-test")
    )
  end

  it "lets Rack app service factories receive the environment and use AI clients" do
    app = Igniter::Application.rack_app(:assistant, root: "/tmp/assistant", env: :test) do
      ai do
        provider :summary, :fake, text: "Ready."
      end

      service(:summary) do |environment|
        -> { environment.ai_client(:summary).complete(model: "fake", input: "state").text }
      end
    end

    expect(app.service(:summary).call).to eq("Ready.")
    expect(app.environment.ai_provider_names).to eq([:summary])
  end
end
