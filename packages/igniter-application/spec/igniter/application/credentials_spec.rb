# frozen_string_literal: true

require "stringio"

require_relative "../../spec_helper"

RSpec.describe Igniter::Application::CredentialStore do
  around do |example|
    original = ENV.fetch("IGNITER_TEST_OPENAI_API_KEY", nil)
    ENV.delete("IGNITER_TEST_OPENAI_API_KEY")
    example.run
  ensure
    if original.nil?
      ENV.delete("IGNITER_TEST_OPENAI_API_KEY")
    else
      ENV["IGNITER_TEST_OPENAI_API_KEY"] = original
    end
  end

  it "reports missing required credentials without leaking values" do
    environment = Igniter::Application.build_kernel
                                      .credential(
                                        :openai_api_key,
                                        env: "IGNITER_TEST_OPENAI_API_KEY",
                                        required: true,
                                        description: "OpenAI API key"
                                      )
                                      .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

    expect(environment.credentials.ready?).to be(false)
    expect(environment.credentials.missing_required).to eq([:openai_api_key])
    expect(environment.credentials.status(:openai_api_key)).to include(
      name: :openai_api_key,
      source: :env,
      env: "IGNITER_TEST_OPENAI_API_KEY",
      required: true,
      configured: false,
      missing: true
    )
    expect do
      environment.credentials.fetch(:openai_api_key)
    end.to raise_error(
      Igniter::Application::MissingCredentialError,
      /IGNITER_TEST_OPENAI_API_KEY/
    )
  end

  it "fetches configured credentials but redacts them from profile and manifest data" do
    ENV["IGNITER_TEST_OPENAI_API_KEY"] = "sk-test-secret"

    environment = Igniter::Application.build_kernel
                                      .manifest(:assistant, root: "/tmp/assistant", env: :test)
                                      .credential(:openai_api_key, env: "IGNITER_TEST_OPENAI_API_KEY", required: true)
                                      .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

    expect(environment.credentials.fetch(:openai_api_key)).to eq("sk-test-secret")
    expect(environment.credentials.ready?).to be(true)
    expect(environment.credentials.status(:openai_api_key)).to include(
      configured: true,
      redacted: "[configured]"
    )

    profile_payload = environment.profile.to_h
    manifest_payload = environment.manifest.to_h

    expect(profile_payload.to_s).not_to include("sk-test-secret")
    expect(manifest_payload.to_s).not_to include("sk-test-secret")
    expect(profile_payload.fetch(:credentials)).to include(
      ready: true,
      credentials: [
        include(
          name: :openai_api_key,
          configured: true,
          redacted: "[configured]"
        )
      ],
      missing_required: []
    )
  end

  it "allows Rack apps to declare credentials in the application manifest" do
    app = Igniter::Application.rack_app(:assistant, root: "/tmp/assistant", env: :test) do
      credential :openai_api_key, env: "IGNITER_TEST_OPENAI_API_KEY", required: false

      get "/setup" do
        text host.environment.credentials.status(:openai_api_key).inspect
      end
    end

    payload = app.to_h.fetch(:manifest).fetch(:credentials)

    expect(payload).to include(ready: true, missing_required: [])
    expect(payload.fetch(:credentials)).to include(
      include(name: :openai_api_key, configured: false, missing: true)
    )

    status, _headers, body = app.call(
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/setup",
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new
    )
    expect(status).to eq(200)
    expect(body.join).to include("openai_api_key")
  end
end
