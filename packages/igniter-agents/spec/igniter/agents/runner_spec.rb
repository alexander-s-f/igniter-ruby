# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Agents::Runner do
  Clock = Struct.new(:now)

  it "runs a single-turn assistant over an AI client" do
    client = Igniter::AI.client(provider: Igniter::AI::Providers::Fake.new(text: "Close one reminder."))
    agent = Igniter::Agents.agent(
      :daily_companion,
      model: "fake",
      instructions: "Give one practical next action.",
      metadata: { capsule: :daily_summary }
    )
    clock = Clock.new(Time.utc(2026, 4, 27, 10, 0, 0))

    run = described_class.new(ai_client: client, clock: clock).run(
      agent,
      id: "run-1",
      input: "Two reminders are open.",
      context: { user: :local },
      metadata: { source: :spec }
    )

    expect(run).to be_success
    expect(run.id).to eq("run-1")
    expect(run.agent_name).to eq(:daily_companion)
    expect(run.turns.first.text).to eq("Close one reminder.")
    expect(run.trace.map(&:type)).to eq(%i[agent_started agent_succeeded])
    expect(run.to_h).to include(
      id: "run-1",
      agent_name: :daily_companion,
      status: :succeeded,
      context: { user: :local }
    )
    expect(run.to_h.fetch(:turns).first.fetch(:request)).to include(
      model: "fake",
      instructions: "Give one practical next action.",
      input: "Two reminders are open.",
      metadata: include(agent: :daily_companion, run_id: "run-1", source: :spec)
    )
  end

  it "returns serializable failed runs when the AI response fails" do
    client = Igniter::AI.client(provider: Igniter::AI::Providers::Fake.new(text: nil, error: :offline))
    agent = Igniter::Agents.agent(:daily_companion, model: "fake")

    run = described_class.new(ai_client: client).run(agent, id: "run-2", input: "state")

    expect(run).to be_failed
    expect(run.error).to eq(:offline)
    expect(run.to_h.fetch(:trace).last).to include(type: :agent_failed, data: { error: :offline })
  end

  it "serializes tool calls as typed agent turn evidence" do
    tool_call = Igniter::Agents::ToolCall.new(
      name: :complete_reminder,
      input: { id: "morning-water" },
      result: { status: :done },
      status: :succeeded
    )
    request = Igniter::AI.request(model: "fake", input: "complete reminder")
    response = Igniter::AI.response(text: "Done.")
    turn = Igniter::Agents::AgentTurn.new(index: 0, request: request, response: response, tool_calls: [tool_call])

    expect(turn.to_h.fetch(:tool_calls)).to eq(
      [
        {
          name: :complete_reminder,
          input: { id: "morning-water" },
          result: { status: :done },
          status: :succeeded
        }
      ]
    )
  end
end
