# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter application agent wiring" do
  it "declares assistant agents over configured AI providers" do
    kernel = Igniter::Application.build_kernel
    kernel.ai do
      provider :summary, :fake, text: "Close one reminder."
    end
    kernel.agents do
      assistant :daily_companion,
                ai: :summary,
                instructions: "Give one practical next action.",
                capsule: :daily_summary
    end
    environment = Igniter::Application::Environment.new(profile: kernel.finalize)

    run = environment.agent(:daily_companion).run(
      id: "run-1",
      input: "Two reminders are open.",
      context: { user: :local }
    )

    expect(run).to be_success
    expect(run.turns.first.text).to eq("Close one reminder.")
    expect(environment.agent_names).to eq([:daily_companion])
    expect(environment.profile.to_h.fetch(:agents)).to include(
      include(
        name: :daily_companion,
        ai_provider: :summary,
        metadata: { capsule: :daily_summary }
      )
    )
  end

  it "lets Rack apps declare agents and use them from service factories" do
    app = Igniter::Application.rack_app(:assistant, root: "/tmp/assistant", env: :test) do
      ai do
        provider :summary, :fake, text: "Ready."
      end

      agents do
        assistant :daily_companion, ai: :summary
      end

      service(:summary) do |environment|
        -> { environment.agent(:daily_companion).run(input: "state").turns.first.text }
      end
    end

    expect(app.service(:summary).call).to eq("Ready.")
    expect(app.environment.agent_names).to eq([:daily_companion])
  end
end
