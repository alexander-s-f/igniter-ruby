# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::MCP::Adapter do
  it "delegates the tooling catalog from igniter-extensions" do
    expect(described_class.tool_names).to include(
      :creator_session_start,
      :creator_session_apply,
      :debug_report
    )

    definition = described_class.tool_definition(:creator_session_apply)

    expect(definition.fetch(:arguments).map { |argument| argument.fetch(:name) }).to eq(%i[session updates])
  end

  it "delegates tool invocation through the MCP tooling surface" do
    environment = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::McpPack)

    result = described_class.invoke(
      :creator_session_start,
      target: environment,
      name: :delivery,
      capabilities: %i[effect executor]
    )

    expect(result.to_h.fetch(:payload).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
  end

  it "delegates creator_session helper through the MCP tooling surface" do
    environment = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::McpPack)

    session = described_class.creator_session(
      target: environment,
      name: :delivery,
      capabilities: %i[effect executor]
    )

    expect(session.to_h.fetch(:payload).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
  end
end
