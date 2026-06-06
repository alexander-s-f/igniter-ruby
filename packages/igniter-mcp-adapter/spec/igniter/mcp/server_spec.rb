# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::MCP::Adapter::Server do
  it "exports transport-ready tool definitions with input schemas" do
    tool = described_class.tool(:creator_session_apply)

    expect(tool.fetch(:name)).to eq("creator_session_apply")
    expect(tool.fetch(:inputSchema).fetch(:required)).to eq(%w[session updates])
    expect(tool.fetch(:inputSchema).fetch(:properties).fetch("updates").fetch(:type)).to eq("object")
    expect(tool.fetch(:annotations).fetch(:readOnlyHint)).to eq(true)
  end

  it "returns MCP-style success envelopes for tool invocations" do
    environment = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::McpPack)

    response = described_class.call(
      :creator_session_start,
      target: environment,
      arguments: {
        name: "delivery",
        capabilities: %w[effect executor]
      }
    )

    expect(response.fetch(:isError)).to eq(false)
    expect(response.fetch(:structuredContent).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
    expect(response.fetch(:content).first.fetch(:type)).to eq("text")
  end

  it "returns MCP-style error envelopes for invalid invocations" do
    response = described_class.call(:debug_report)

    expect(response.fetch(:isError)).to eq(true)
    expect(response.fetch(:structuredContent).fetch(:error).fetch(:class)).to include("ArgumentError")
  end
end
