# frozen_string_literal: true

require "json"
require "stringio"

require_relative "../../spec_helper"

RSpec.describe Igniter::MCP::Adapter::Host do
  def framed(payload)
    body = JSON.generate(payload)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def parse_response(io)
    io.rewind
    described_class.new.read_message(io)
  end

  it "handles initialize requests" do
    host = described_class.new

    response = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "initialize"
    )

    expect(response.fetch(:result).fetch(:protocolVersion)).to eq("2024-11-05")
    expect(response.fetch(:result).fetch(:serverInfo).fetch(:name)).to eq("igniter-mcp-adapter")
  end

  it "handles tools/list and tools/call requests" do
    host = described_class.new

    tools = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list"
    )

    call = host.handle_message(
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        name: "creator_session_start",
        arguments: {
          name: "delivery",
          capabilities: %w[effect executor]
        }
      }
    )

    expect(tools.fetch(:result).fetch(:tools).map { |tool| tool.fetch(:name) }).to include("creator_session_start")
    expect(call.fetch(:result).fetch(:structuredContent).fetch(:pending_decisions).first.fetch(:key)).to eq(:scope)
  end

  it "writes and reads framed stdio messages" do
    host = described_class.new
    input = StringIO.new(
      framed(
        jsonrpc: "2.0",
        id: 1,
        method: "ping"
      )
    )
    output = StringIO.new

    host.serve(input: input, output: output)
    response = parse_response(output)

    expect(response.fetch(:id)).to eq(1)
    expect(response.fetch(:result)).to eq({})
  end

  it "returns JSON-RPC errors for unknown methods" do
    host = described_class.new

    response = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "unknown/method"
    )

    expect(response.fetch(:error).fetch(:code)).to eq(-32_601)
  end

  it "returns JSON-RPC invalid params for missing required tool arguments" do
    host = described_class.new

    response = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "creator_session_apply",
        arguments: {
          session: {}
        }
      }
    )

    expect(response.fetch(:error).fetch(:code)).to eq(-32_602)
    expect(response.fetch(:error).fetch(:message)).to include("missing required arguments")
  end

  it "returns JSON-RPC invalid params for unknown tool arguments" do
    host = described_class.new

    response = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "creator_session_start",
        arguments: {
          name: "delivery",
          capabilities: %w[effect executor],
          unexpected: true
        }
      }
    )

    expect(response.fetch(:error).fetch(:code)).to eq(-32_602)
    expect(response.fetch(:error).fetch(:message)).to include("unknown arguments")
  end

  it "returns JSON-RPC invalid params for enum violations" do
    host = described_class.new

    response = host.handle_message(
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "creator_write_plan",
        arguments: {
          name: "slug",
          scope: "bad_scope",
          root: "."
        }
      }
    )

    expect(response.fetch(:error).fetch(:code)).to eq(-32_602)
    expect(response.fetch(:error).fetch(:message)).to include("must be one of")
  end
end
