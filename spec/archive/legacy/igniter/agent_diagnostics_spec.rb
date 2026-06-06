# frozen_string_literal: true

require "spec_helper"
require "igniter/agent"
require "igniter/extensions/provenance"

RSpec.describe "agent diagnostics and provenance" do
  around do |example|
    previous_adapter = Igniter::Runtime.agent_adapter
    Igniter::Runtime.activate_agent_adapter!
    Igniter::Registry.clear
    example.run
    Igniter::Registry.clear
    Igniter::Runtime.agent_adapter = previous_adapter
  end

  let(:greeter_class) do
    Class.new(Igniter::Agent) do
      initial_state names: []

      on :greet do |payload:, **|
        "Hello, #{payload.fetch(:name)}"
      end

      on :remember do |state:, payload:, **|
        state.merge(names: state[:names] + [payload.fetch(:name)])
      end
    end
  end

  it "surfaces successful agent delivery in diagnostics and runtime state" do
    ref = greeter_class.start(name: :greeter)

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :name
        agent :greeting, via: :greeter, message: :greet, inputs: { name: :name }
        output :greeting
      end
    end

    contract = contract_class.new(name: "Alice")
    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown
    state = contract.execution.states.fetch(:greeting)

    expect(report[:status]).to eq(:succeeded)
    expect(report[:agents]).to include(total: 1, succeeded: 1, pending: 0, failed: 0)
    expect(report[:agents][:facets]).to include(
      by_status: { succeeded: 1 },
      by_mode: { call: 1 },
      by_adapter: { registry: 1 },
      by_outcome: { replied: 1 }
    )
    expect(report[:agents][:entries]).to contain_exactly(
      include(
        node_name: :greeting,
        status: :succeeded,
        agent_trace: include(
          adapter: :registry,
          mode: :call,
          via: :greeter,
          message: :greet,
          outcome: :replied
        ),
        agent_trace_summary: "adapter=registry mode=call via=greeter message=greet local=true registered=true alive=true outcome=replied"
      )
    )
    expect(state[:details]).to include(
      agent_trace: include(adapter: :registry, mode: :call, outcome: :replied)
    )
    expect(text).to include("Agents: total=1, succeeded=1, pending=0, failed=0")
    expect(text).to include("adapter=registry mode=call via=greeter message=greet")
    expect(markdown).to include("## Agents")
    expect(markdown).to include("`greeting` `succeeded`")

    ref.stop
  end

  it "surfaces failed agent delivery in diagnostics outputs and errors" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :name
        agent :greeting, via: :greeter, message: :greet, inputs: { name: :name }
        output :greeting
      end
    end

    contract = contract_class.new(name: "Alice")
    report = contract.diagnostics.to_h
    text = contract.diagnostics_text

    expect(report[:status]).to eq(:failed)
    expect(report[:outputs][:greeting]).to include(
      status: :failed,
      agent_trace: include(reason: :not_registered),
      agent_trace_summary: "adapter=registry mode=call via=greeter message=greet local=true registered=false alive=false reason=not_registered"
    )
    expect(report[:errors].first).to include(
      node_name: :greeting,
      agent_trace: include(reason: :not_registered),
      agent_trace_summary: "adapter=registry mode=call via=greeter message=greet local=true registered=false alive=false reason=not_registered"
    )
    expect(report[:agents]).to include(total: 1, succeeded: 0, pending: 0, failed: 1)
    expect(report[:agents][:facets]).to include(
      by_status: { failed: 1 },
      by_reason: { not_registered: 1 }
    )
    expect(text).to include("reasons=not_registered=1")
  end

  it "surfaces pending agent traces in diagnostics and provenance" do
    trace = {
      adapter: :queue,
      mode: :call,
      via: :reviewer,
      message: :review,
      outcome: :deferred,
      reason: :awaiting_review
    }

    adapter = Class.new do
      define_method(:call) do |**|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: trace
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      runner :inline, agent_adapter: adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        output :approval
      end
    end

    contract = contract_class.new(name: "Alice")
    report = contract.diagnostics.to_h
    trace_value = contract.lineage(:approval).trace.value

    expect(report[:status]).to eq(:pending)
    expect(report[:outputs][:approval]).to include(
      agent_trace: trace,
      agent_session: include(
        token: kind_of(String),
        node_name: :approval,
        agent_name: :reviewer,
        message_name: :review,
        mode: :call,
        reply_mode: :deferred,
        phase: :waiting,
        last_request: include(
          turn: 1,
          kind: :request,
          name: :review,
          reply_mode: :deferred,
          payload: { queue: :review }
        )
      ),
      agent_trace_summary: "adapter=queue mode=call via=reviewer message=review outcome=deferred reason=awaiting_review"
    )
    expect(report[:agents]).to include(total: 1, succeeded: 0, pending: 1, failed: 0)
    expect(report[:agents][:facets]).to include(
      by_status: { pending: 1 },
      by_reply_mode: { deferred: 1 },
      by_adapter: { queue: 1 },
      by_reason: { awaiting_review: 1 }
    )
    expect(trace_value).to include(
      pending: true,
      agent_trace: trace
    )
  end

  it "surfaces successful cast delivery as an agent execution entry" do
    ref = greeter_class.start(name: :greeter)

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :name
        agent :notify, via: :greeter, message: :remember, mode: :cast, inputs: { name: :name }
        output :notify
      end
    end

    contract = contract_class.new(name: "Alice")
    report = contract.diagnostics.to_h

    expect(report[:status]).to eq(:succeeded)
    expect(report[:agents][:entries]).to contain_exactly(
      include(
        node_name: :notify,
        status: :succeeded,
        agent_trace: include(
          adapter: :registry,
          mode: :cast,
          outcome: :sent
        ),
        agent_trace_summary: "adapter=registry mode=cast via=greeter message=remember local=true registered=true alive=true outcome=sent"
      )
    )

    ref.stop
  end
end
