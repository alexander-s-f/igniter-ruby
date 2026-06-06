# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe Igniter::Server::AgentTransport do
  let(:transport) { described_class.new }

  it "declares session lifecycle support" do
    expect(transport.session_lifecycle?).to be(true)
  end

  it "supports static remote agent calls" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :greeter,
      message: :greet,
      url: "http://localhost:4568"
    )
    node = Igniter::Model::AgentNode.new(
      id: "test:1",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data },
      node_url: "http://localhost:4568"
    )

    client = instance_double(Igniter::Server::Client)
    allow(Igniter::Server::Client).to receive(:new).with("http://localhost:4568", timeout: 5).and_return(client)
    allow(client).to receive(:call_agent).with(
      via: :greeter,
      message: :greet,
      inputs: { name: "Alice" },
      timeout: 5,
      reply_mode: :deferred
    ).and_return(
      status: :succeeded,
      output: "Hello, Alice",
      agent_trace: { adapter: :server_remote, outcome: :replied }
    )

    result = transport.call(route: route, node: node, inputs: { name: "Alice" })

    expect(result).to include(status: :succeeded, output: "Hello, Alice")
    expect(result[:agent_trace]).to include(adapter: :server_remote, outcome: :replied)
  end

  it "rebuilds a deferred result for pending remote agent replies" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :reviewer,
      message: :review,
      url: "http://localhost:4568"
    )
    node = Igniter::Model::AgentNode.new(
      id: "test:2",
      name: :approval,
      agent_name: :reviewer,
      message_name: :review,
      input_mapping: { name: :data },
      node_url: "http://localhost:4568"
    )

    client = instance_double(Igniter::Server::Client)
    allow(Igniter::Server::Client).to receive(:new).with("http://localhost:4568", timeout: 5).and_return(client)
    allow(client).to receive(:call_agent).and_return(
      status: :pending,
      message: "continue",
      deferred_result: {
        token: "remote-session",
        source_node: :approval,
        waiting_on: :approval,
        payload: { requested_name: "Alice" }
      },
      payload: { requested_name: "Alice" },
      agent_trace: { adapter: :server_remote, outcome: :pending }
    )

    result = transport.call(route: route, node: node, inputs: { name: "Alice" })

    expect(result).to include(status: :pending, message: "continue")
    expect(result[:deferred_result]).to have_attributes(
      token: "remote-session",
      source_node: :approval,
      waiting_on: :approval
    )
    expect(result[:deferred_result].payload).to eq(requested_name: "Alice")
  end

  it "continues remote-owned agent sessions over the server protocol" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :reviewer,
      message: :review,
      url: "http://localhost:4568"
    )
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-session",
      node_name: :approval,
      agent_name: :reviewer,
      message_name: :review,
      mode: :call,
      reply_mode: :deferred,
      ownership: :remote,
      owner_url: "http://localhost:4568",
      delivery_route: { routing_mode: :static, url: "http://localhost:4568", remote: true },
      payload: { requested_name: "Alice" }
    )

    client = instance_double(Igniter::Server::Client)
    allow(Igniter::Server::Client).to receive(:new).with("http://localhost:4568", timeout: 5).and_return(client)
    allow(client).to receive(:continue_agent_session).with(
      token: "remote-session",
      session: session.to_h,
      payload: { step: 2 },
      trace: nil,
      next_token: nil,
      waiting_on: nil,
      request: nil,
      reply: nil,
      phase: nil
    ).and_return(
      status: :pending,
      message: "continue",
      deferred_result: {
        token: "remote-session",
        source_node: :approval,
        waiting_on: :approval,
        payload: { step: 2 }
      },
      payload: { step: 2 },
      agent_trace: { adapter: :server_remote, outcome: :continued }
    )

    result = transport.continue_session(route: route, session: session, payload: { step: 2 })

    expect(result).to include(status: :pending, message: "continue")
    expect(result[:deferred_result]).to have_attributes(token: "remote-session")
    expect(result[:deferred_result].payload).to eq(step: 2)
  end

  it "resumes remote-owned agent sessions over the server protocol when value is explicit" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :reviewer,
      message: :review,
      url: "http://localhost:4568"
    )
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-session",
      node_name: :approval,
      agent_name: :reviewer,
      message_name: :review,
      mode: :call,
      reply_mode: :deferred,
      ownership: :remote,
      owner_url: "http://localhost:4568",
      delivery_route: { routing_mode: :static, url: "http://localhost:4568", remote: true },
      payload: { requested_name: "Alice" }
    )

    client = instance_double(Igniter::Server::Client)
    allow(Igniter::Server::Client).to receive(:new).with("http://localhost:4568", timeout: 5).and_return(client)
    allow(client).to receive(:resume_agent_session).with(
      token: "remote-session",
      session: session.to_h,
      value: "approved"
    ).and_return(
      status: :succeeded,
      output: "approved",
      agent_trace: { adapter: :server_remote, outcome: :completed }
    )

    result = transport.resume_session(route: route, session: session, value: "approved")

    expect(result).to include(status: :succeeded, output: "approved")
    expect(result[:agent_trace]).to include(adapter: :server_remote, outcome: :completed)
  end

  it "falls back to local graph-owned resume when no explicit value is given" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :reviewer,
      message: :review,
      url: "http://localhost:4568"
    )
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-session",
      node_name: :approval,
      agent_name: :reviewer,
      message_name: :review,
      mode: :call,
      reply_mode: :stream,
      ownership: :remote,
      owner_url: "http://localhost:4568",
      delivery_route: { routing_mode: :static, url: "http://localhost:4568", remote: true }
    )

    expect(transport.resume_session(route: route, session: session, value: nil)).to be_nil
  end
end
