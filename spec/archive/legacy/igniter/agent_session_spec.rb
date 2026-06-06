# frozen_string_literal: true

require "spec_helper"

RSpec.describe "agent sessions" do
  let(:trace) do
    {
      adapter: :queue,
      mode: :call,
      via: :reviewer,
      message: :review,
      outcome: :deferred,
      reason: :awaiting_review
    }
  end

  let(:adapter) do
    pending_trace = trace
    Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: pending_trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: pending_trace
          }
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new
  end

  let(:contract_class) do
    custom_adapter = adapter
    Class.new(Igniter::Contract) do
      runner :inline, agent_adapter: custom_adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        compute :final_answer, depends_on: :approval do |approval:|
          "approved: #{approval}"
        end
        output :approval
        output :final_answer
      end
    end
  end

  it "exposes pending agent nodes as first-class runtime sessions" do
    contract = contract_class.new(name: "Alice")

    expect(contract.result.approval).to be_a(Igniter::Runtime::DeferredResult)

    sessions = contract.execution.agent_sessions
    expect(sessions.size).to eq(1)

    session = sessions.first
    expect(session).to be_a(Igniter::Runtime::AgentSession)
    expect(session.token).not_to be_nil
    expect(session.node_name).to eq(:approval)
    expect(session.agent_name).to eq(:reviewer)
    expect(session.message_name).to eq(:review)
    expect(session.mode).to eq(:call)
    expect(session.reply_mode).to eq(:deferred)
    expect(session.turn).to eq(1)
    expect(session.phase).to eq(:waiting)
    expect(session.messages).to contain_exactly(
      include(turn: 1, kind: :request, name: :review, source: :contract, reply_mode: :deferred, payload: { queue: :review })
    )
    expect(session.interaction_contract.to_h).to eq(
      mode: :call,
      routing_mode: :local,
      reply: :deferred,
      finalizer: nil,
      tool_loop_policy: nil,
      session_policy: nil
    )
    expect(session.last_request).to include(
      turn: 1,
      kind: :request,
      name: :review,
      reply_mode: :deferred,
      payload: { queue: :review }
    )
    expect(session.last_reply).to be_nil
    expect(session.history).to contain_exactly(
      include(turn: 1, event: :opened, token: session.token)
    )
    expect(session.trace).to eq(trace)
    expect(session.execution_id).to eq(contract.execution.events.execution_id)
    expect(session.graph).to eq(contract.execution.compiled_graph.name)
    expect(contract.result.approval.agent_result_contract.to_h).to include(
      kind: :deferred,
      waiting_on: :approval,
      source_node: :approval,
      session_lifecycle_state: :waiting,
      phase: :waiting,
      interaction_contract: include(
        mode: :call,
        routing_mode: :local,
        reply: :deferred
      ),
      ownership: :local,
      interactive: false,
      continuable: true,
      routed: false
    )
  end

  it "continues agent work across multiple turns before final resume" do
    contract = contract_class.new(name: "Alice")
    contract.result.approval
    session = contract.execution.agent_sessions.first
    continued_trace = trace.merge(reason: :awaiting_human_reply)

    contract.execution.continue_agent_session(
      session,
      payload: { prompt: "Need manager approval" },
      trace: continued_trace
    )

    continued = contract.execution.agent_sessions.first

    expect(contract.result.pending?).to be true
    expect(continued.token).to eq(session.token)
    expect(continued.turn).to eq(2)
    expect(continued.phase).to eq(:waiting)
    expect(continued.trace).to eq(continued_trace)
    expect(continued.payload).to eq(prompt: "Need manager approval")
    expect(continued.last_request).to include(
      turn: 2,
      kind: :request,
      name: :review,
      source: :continuation,
      reply_mode: :deferred,
      payload: { prompt: "Need manager approval" }
    )
    expect(continued.messages).to include(
      include(turn: 1, kind: :request, name: :review),
      include(turn: 2, kind: :request, name: :review, payload: { prompt: "Need manager approval" })
    )
    expect(continued.history).to include(
      include(turn: 1, event: :opened, token: session.token),
      include(turn: 2, event: :continued, token: session.token, payload: { prompt: "Need manager approval" })
    )
    expect(contract.events.map(&:type)).to include(:agent_session_continued, :node_pending)

    contract.execution.resume_agent_session(continued, value: "ok")

    report = contract.diagnostics.to_h
    entry = report.dig(:agents, :entries)&.find { |item| item[:node_name] == :approval }

    expect(contract.result.final_answer).to eq("approved: ok")
    expect(entry[:agent_session]).to include(
      token: session.token,
      turn: 3,
      phase: :completed
    )
    expect(entry[:agent_session][:last_reply]).to include(
      turn: 3,
      kind: :reply,
      name: :review,
      reply_mode: :deferred,
      payload: { value: "ok" }
    )
    expect(entry[:agent_session][:messages]).to include(
      include(turn: 3, kind: :reply, name: :review, reply_mode: :deferred, payload: { value: "ok" })
    )
    expect(entry[:agent_session][:history]).to include(
      include(turn: 3, event: :completed, token: session.token)
    )
  end

  it "resumes pending agent work through the session handle" do
    contract = contract_class.new(name: "Alice")
    contract.result.approval
    session = contract.execution.agent_sessions.first

    contract.execution.resume_agent_session(session, value: "ok")

    expect(contract.result.approval).to eq("ok")
    expect(contract.result.final_answer).to eq("approved: ok")
    expect(contract.execution.find_agent_session(session.token)).to be_nil
  end

  it "serializes and restores agent sessions through execution snapshots" do
    original = contract_class.new(name: "Alice")
    original.result.final_answer
    snapshot = original.snapshot

    restored = contract_class.restore(snapshot)
    session = restored.execution.agent_sessions.first

    expect(session.token).not_to be_nil
    expect(session.agent_name).to eq(:reviewer)
    expect(session.turn).to eq(1)
    expect(session.phase).to eq(:waiting)
    expect(session.trace).to eq(trace)

    restored.execution.resume_agent_session(session.token, value: "approved")

    expect(restored.result.final_answer).to eq("approved: approved")
  end

  it "supports read-only queries over live agent sessions" do
    trace_copy = trace
    adapter = Class.new do
      define_method(:call) do |node:, **|
        payload =
          if node.reply_mode == :stream
            { event: Igniter::Runtime::AgentSession.status_event(status: "thinking") }
          else
            { queue: :review }
          end

        {
          status: :pending,
          payload: payload,
          agent_trace: trace_copy,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace_copy
          }
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

        agent :interactive_summary,
              via: :writer,
              message: :summarize,
              reply: :stream,
              inputs: { name: :name }

        agent :approval,
              via: :reviewer,
              message: :review,
              inputs: { name: :name }

        output :interactive_summary
        output :approval
      end
    end

    contract = contract_class.new(name: "Alice")
    contract.result.interactive_summary
    contract.result.approval

    query = contract.execution.agent_session_query

    expect(query).to be_a(Igniter::Runtime::AgentSessionQuery)
    expect(query.count).to eq(2)
    expect(query.with_agent(:writer).for_node(:interactive_summary).reply_mode(:stream).phase(:streaming).tool_loop_status(:idle).to_a.map(&:node_name)).to eq([:interactive_summary])
    expect(query.interaction(:interactive_session).attention_required.to_a.map(&:node_name)).to eq([:interactive_summary])
    expect(query.interaction(:deferred_call).reason(:deferred_call).resumable.to_a.map(&:node_name)).to eq([:approval])
    expect(query.order_by(:node_name, direction: :asc).first.node_name).to eq(:approval)
    expect(query.limit(1).to_a.size).to eq(1)
    expect(query.facet(:reply_mode)).to eq(stream: 1, deferred: 1)
    expect(query.facet(:routing_mode)).to eq(local: 2)
    expect(query.facet(:session_policy)).to eq(interactive: 1)
    expect(query.facet(:tool_loop_policy)).to eq(complete: 1)
    expect(query.facet(:finalizer)).to eq(join: 1)
    expect(query.facet(:ownership)).to eq(local: 2)
    expect(query.facet(:lifecycle_state)).to eq(streaming: 1, waiting: 1)
    expect(query.facet(:interaction)).to eq(interactive_session: 1, deferred_call: 1)
    expect(query.routing_mode(:local).session_policy(:interactive).tool_loop_policy(:complete).finalizer(:join).to_a.map(&:node_name)).to eq([:interactive_summary])
    expect(query.interactive.to_a.map(&:node_name)).to eq([:interactive_summary])
    expect(query.continuable.to_a.map(&:node_name)).to contain_exactly(:interactive_summary, :approval)
    expect(query.routed(false).count).to eq(2)
    expect(query.facets(:agent_name, :reason, :ownership)).to eq(
      agent_name: { writer: 1, reviewer: 1 },
      reason: { interactive_session: 1, deferred_call: 1 },
      ownership: { local: 2 }
    )
    expect(query.summary).to include(
      total: 2,
      by_agent: { writer: 1, reviewer: 1 },
      by_reply_mode: { stream: 1, deferred: 1 },
      by_routing_mode: { local: 2 },
      by_session_policy: { interactive: 1 },
      by_tool_loop_policy: { complete: 1 },
      by_finalizer: { join: 1 },
      by_ownership: { local: 2 },
      by_lifecycle_state: { streaming: 1, waiting: 1 },
      by_interaction: { interactive_session: 1, deferred_call: 1 },
      interactive: 1,
      terminal: 0,
      continuable: 2,
      routed: 0,
      attention_required: 2,
      resumable: 2
    )
    expect(contract.agent_session_summary).to include(total: 2)
    expect(query.explain).to include("AgentSessionQuery(2 candidates)")
    expect(query.explain).to include("filters: 0")
  end

  it "infers remote ownership and delivery route from agent trace" do
    session = Igniter::Runtime::AgentSession.new(
      token: "remote-1",
      node_name: :summary,
      agent_name: :writer,
      message_name: :summarize,
      mode: :call,
      reply_mode: :stream,
      trace: {
        adapter: :remote_agent,
        routing_mode: :static,
        route_url: "http://agents:4567",
        remote: true
      },
      payload: { requested_name: "Alice" }
    )

    expect(session).to be_remote_owned
    expect(session.owner_url).to eq("http://agents:4567")
    expect(session).to be_routed
    expect(session.interaction_contract.to_h).to include(
      mode: :call,
      routing_mode: :static,
      reply: :stream,
      finalizer: :join,
      tool_loop_policy: :complete,
      session_policy: :interactive,
      node: "http://agents:4567"
    )
    expect(session.lifecycle).to include(
      state: :streaming,
      ownership: :remote,
      owner_url: "http://agents:4567",
      routed: true,
      interactive: true,
      terminal: false,
      continuable: true,
      tool_loop_status: :idle
    )
    expect(session.delivery_route).to include(
      routing_mode: :static,
      url: "http://agents:4567",
      remote: true
    )
    expect(Igniter::Runtime::AgentSession.from_h(session.to_h)).to have_attributes(
      ownership: :remote,
      owner_url: "http://agents:4567"
    )
    expect(Igniter::Runtime::AgentSession.from_h(session.to_h).lifecycle).to include(
      ownership: :remote,
      routed: true
    )
  end

  it "exposes a runtime-owned orchestration overview over live execution state" do
    trace_copy = trace
    adapter = Class.new do
      define_method(:call) do |node:, **|
        payload =
          if node.reply_mode == :stream
            { event: Igniter::Runtime::AgentSession.status_event(status: "thinking") }
          else
            { queue: :review }
          end

        {
          status: :pending,
          payload: payload,
          agent_trace: trace_copy,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace_copy
          }
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

        agent :interactive_summary,
              via: :writer,
              message: :summarize,
              reply: :stream,
              inputs: { name: :name }

        agent :approval,
              via: :reviewer,
              message: :review,
              inputs: { name: :name }

        output :interactive_summary
        output :approval
      end
    end

    contract = contract_class.new(name: "Alice")
    contract.result.interactive_summary
    contract.result.approval

    approval_session = contract.execution.agent_sessions.find { |session| session.node_name == :approval }
    contract.execution.continue_agent_session(
      approval_session,
      payload: { prompt: "Need manager approval" },
      trace: trace.merge(reason: :awaiting_manager)
    )

    overview = contract.execution.orchestration_overview

    expect(contract.orchestration_overview).to eq(overview)
    expect(contract.execution.orchestration_summary).to eq(overview[:summary])
    expect(overview[:summary]).to include(
      total: 2,
      attention_required: 2,
      resumable: 2,
      with_session: 2,
      interactive_sessions: 1,
      deferred_calls: 1,
      by_action: {
        open_interactive_session: 1,
        await_deferred_reply: 1
      },
      by_interaction: {
        interactive_session: 1,
        deferred_call: 1
      },
      by_runtime_status: { pending_session: 2 },
      by_session_lifecycle_state: {
        streaming: 1,
        waiting: 1
      },
      by_ownership: { local: 2 },
      by_phase: {
        streaming: 1,
        waiting: 1
      },
      by_reply_mode: {
        stream: 1,
        deferred: 1
      }
    )
    expect(overview[:summary][:by_event_type]).to include(
      node_pending: 3,
      agent_session_continued: 1
    )
    expect(overview[:records]).to contain_exactly(
      include(
        node: :interactive_summary,
        action: :open_interactive_session,
        interaction: :interactive_session,
        runtime_status: :pending_session,
        session_lifecycle_state: :streaming,
        ownership: :local,
        interactive: true,
        continuable: true,
        routed: false
      ),
      include(
        node: :approval,
        action: :await_deferred_reply,
        interaction: :deferred_call,
        runtime_status: :pending_session,
        session_lifecycle_state: :waiting,
        ownership: :local,
        waiting_on: :approval,
        interactive: false,
        continuable: true,
        routed: false
      )
    )
    expect(overview[:timeline]).to include(
      include(node: :interactive_summary, event: :node_pending),
      include(node: :approval, event: :agent_session_continued, turn: 2)
    )
  end
end
