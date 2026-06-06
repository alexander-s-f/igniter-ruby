# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Runtime::AgentAdapter do
  let(:adapter) { described_class.new }
  let(:node) do
    Igniter::Model::AgentNode.new(
      id: "test:1",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data }
    )
  end

  it "defaults call nodes to reply: :deferred" do
    expect(node.reply_mode).to eq(:deferred)
  end

  it "raises a helpful error when no agent adapter is configured" do
    expect {
      adapter.call(node: node, inputs: { name: "Alice" })
    }.to raise_error(Igniter::ResolutionError, /agent adapter|igniter\/agent|agent_adapter/)
  end

  it "raises a helpful error for cast delivery when no agent adapter is configured" do
    cast_node = Igniter::Model::AgentNode.new(
      id: "test:2",
      name: :notify,
      agent_name: :greeter,
      message_name: :remember,
      input_mapping: { name: :data },
      mode: :cast
    )

    expect(cast_node.reply_mode).to eq(:none)

    expect {
      adapter.cast(node: cast_node, inputs: { name: "Alice" })
    }.to raise_error(Igniter::ResolutionError, /agent adapter|igniter\/agent|agent_adapter/)
  end

  it "can be injected through execution options without loading the agents runtime" do
    custom_adapter = instance_double("CustomAgentAdapter")

    contract_class = Class.new(Igniter::Contract) do
      runner :inline, agent_adapter: custom_adapter

      define do
        input :data
        agent :result,
              via: :greeter,
              message: :greet,
              inputs: { name: :data }
        output :result
      end
    end

    allow(custom_adapter).to receive(:call).and_return(
      status: :succeeded,
      output: "Hello, Alice"
    )

    contract = contract_class.new(data: "Alice")
    contract.resolve_all

    expect(custom_adapter).to have_received(:call).with(
      hash_including(
        node: kind_of(Igniter::Model::AgentNode),
        inputs: { name: "Alice" },
        execution: kind_of(Igniter::Runtime::Execution)
      )
    )
    expect(contract.result.result).to eq("Hello, Alice")
  end

  it "can deliver a cast through an injected adapter" do
    custom_adapter = instance_double("CustomAgentAdapter")

    contract_class = Class.new(Igniter::Contract) do
      runner :inline, agent_adapter: custom_adapter

      define do
        input :data
        agent :notify,
              via: :greeter,
              message: :remember,
              mode: :cast,
              inputs: { name: :data }
        output :notify
      end
    end

    allow(custom_adapter).to receive(:cast).and_return(
      status: :succeeded,
      output: nil
    )

    contract = contract_class.new(data: "Alice")
    contract.resolve_all

    expect(custom_adapter).to have_received(:cast).with(
      hash_including(
        node: kind_of(Igniter::Model::AgentNode),
        inputs: { name: "Alice" },
        execution: kind_of(Igniter::Runtime::Execution)
      )
    )
    expect(contract.result.notify).to be_nil
  end

  it "maps local agent pending replies to a runtime pending response" do
    previous_adapter = Igniter::Runtime.agent_adapter
    Igniter::Runtime.activate_agent_adapter!
    Igniter::Registry.clear
    ref = nil

    agent_class = Class.new(Igniter::Agent) do
      on :greet do |payload:, **|
        raise Igniter::PendingDependencyError.new(
          "continue",
          token: "greeter-session",
          source_node: :greeting,
          payload: { requested_name: payload[:name] }
        )
      end
    end

    ref = agent_class.start(name: :greeter)
    registry_adapter = Igniter::Runtime::RegistryAgentAdapter.new

    response = registry_adapter.call(node: node, inputs: { name: "Alice" })

    expect(response).to include(
      status: :pending,
      message: "continue",
      payload: { requested_name: "Alice" }
    )
    expect(response[:deferred_result]).to have_attributes(
      token: "greeter-session",
      source_node: :greeting,
      waiting_on: :greeting
    )
    expect(response[:agent_trace]).to include(
      adapter: :registry,
      via: :greeter,
      message: :greet,
      outcome: :pending
    )
  ensure
    ref&.stop
    Igniter::Registry.clear
    Igniter::Runtime.agent_adapter = previous_adapter
  end
end

RSpec.describe Igniter::Runtime::AgentRouteResolver do
  it "returns a local route for default agent delivery" do
    node = Igniter::Model::AgentNode.new(
      id: "test:local",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data }
    )

    route = described_class.new.resolve(node: node)

    expect(route.to_h).to include(
      routing_mode: :local,
      via: :greeter,
      message: :greet
    )
    expect(route).to be_local
  end

  it "returns a static route when node: is configured" do
    node = Igniter::Model::AgentNode.new(
      id: "test:static",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data },
      node_url: "http://agents:4567"
    )

    route = described_class.new.resolve(node: node)

    expect(route.to_h).to include(
      routing_mode: :static,
      via: :greeter,
      message: :greet,
      url: "http://agents:4567"
    )
    expect(route).to be_remote
  end

  it "raises a helpful error for cluster-only routing modes" do
    node = Igniter::Model::AgentNode.new(
      id: "test:capability",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data },
      capability: :review
    )

    expect {
      described_class.new.resolve(node: node)
    }.to raise_error(Igniter::ResolutionError, /add `require 'igniter\/cluster'`/)
  end
end

RSpec.describe Igniter::Runtime::ProxyAgentAdapter do
  let(:local_adapter) { instance_double("LocalAgentAdapter") }
  let(:route_resolver) { instance_double("AgentRouteResolver") }
  let(:transport) { instance_double("AgentTransport") }
  let(:adapter) do
    described_class.new(
      local_adapter: local_adapter,
      route_resolver: route_resolver,
      transport: transport
    )
  end
  let(:node) do
    Igniter::Model::AgentNode.new(
      id: "test:proxy",
      name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      input_mapping: { name: :data }
    )
  end

  it "delegates local routes to the local adapter" do
    route = Igniter::Runtime::AgentRoute.local(via: :greeter, message: :greet)
    allow(route_resolver).to receive(:resolve).and_return(route)
    allow(local_adapter).to receive(:call).and_return(
      status: :succeeded,
      output: "Hello, Alice",
      agent_trace: { adapter: :registry, outcome: :replied }
    )

    response = adapter.call(node: node, inputs: { name: "Alice" })

    expect(local_adapter).to have_received(:call).with(
      node: node,
      inputs: { name: "Alice" },
      execution: nil
    )
    expect(response).to include(status: :succeeded, output: "Hello, Alice")
    expect(response[:agent_trace]).to include(
      adapter: :registry,
      routing_mode: :local,
      remote: false,
      outcome: :replied
    )
  end

  it "delegates remote routes to the transport" do
    route = Igniter::Runtime::AgentRoute.static(
      via: :greeter,
      message: :greet,
      url: "http://agents:4567",
      capability: :review
    )
    allow(route_resolver).to receive(:resolve).and_return(route)
    allow(transport).to receive(:call).and_return(
      status: :succeeded,
      output: "Hello remotely",
      agent_trace: { adapter: :http_agent, outcome: :replied }
    )

    response = adapter.call(node: node, inputs: { name: "Alice" })

    expect(transport).to have_received(:call).with(
      route: route,
      node: node,
      inputs: { name: "Alice" },
      execution: nil
    )
    expect(response).to include(status: :succeeded, output: "Hello remotely")
    expect(response[:agent_trace]).to include(
      adapter: :http_agent,
      routing_mode: :static,
      route_url: "http://agents:4567",
      capability: :review,
      remote: true
    )
  end

  it "delegates remote session continuation to the transport" do
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-1",
      node_name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      mode: :call,
      ownership: :remote,
      owner_url: "http://agents:4567",
      delivery_route: { routing_mode: :static, url: "http://agents:4567", remote: true }
    )

    allow(transport).to receive(:continue_session).and_return(
      status: :pending,
      agent_trace: { adapter: :http_agent, outcome: :continued }
    )
    allow(transport).to receive(:session_lifecycle?).and_return(true)

    response = adapter.continue_session(session: session, payload: { step: 2 })

    expect(transport).to have_received(:continue_session).with(
      route: have_attributes(routing_mode: :static, url: "http://agents:4567", via: :greeter, message: :greet),
      session: session,
      payload: { step: 2 },
      execution: nil,
      trace: nil,
      token: nil,
      waiting_on: nil,
      request: nil,
      reply: nil,
      phase: nil
    )
    expect(response[:agent_trace]).to include(
      adapter: :http_agent,
      routing_mode: :static,
      route_url: "http://agents:4567",
      remote: true
    )
  end

  it "delegates remote session resume to the transport" do
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-1",
      node_name: :greeting,
      agent_name: :greeter,
      message_name: :greet,
      mode: :call,
      ownership: :remote,
      owner_url: "http://agents:4567",
      delivery_route: { routing_mode: :static, url: "http://agents:4567", remote: true }
    )

    allow(transport).to receive(:resume_session).and_return(
      status: :succeeded,
      output: "done",
      agent_trace: { adapter: :http_agent, outcome: :completed }
    )
    allow(transport).to receive(:session_lifecycle?).and_return(true)

    response = adapter.resume_session(session: session, value: "done")

    expect(transport).to have_received(:resume_session).with(
      route: have_attributes(routing_mode: :static, url: "http://agents:4567", via: :greeter, message: :greet),
      session: session,
      execution: nil,
      value: "done"
    )
    expect(response[:agent_trace]).to include(
      adapter: :http_agent,
      routing_mode: :static,
      route_url: "http://agents:4567",
      remote: true
    )
  end
end
