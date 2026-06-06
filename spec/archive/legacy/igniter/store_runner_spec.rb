# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter store-backed execution" do
  around do |example|
    original_store = Igniter.execution_store
    Igniter.execution_store = Igniter::Runtime::Stores::MemoryStore.new
    example.run
    Igniter.execution_store = original_store
  end

  class StoredAsyncExecutor < Igniter::Executor
    input :order_total, type: :numeric

    def call(order_total:)
      defer(token: "stored-#{order_total}", payload: { kind: "quote" })
    end
  end

  let(:pending_agent_trace) do
    {
      adapter: :queue,
      mode: :call,
      via: :reviewer,
      message: :review,
      outcome: :deferred,
      reason: :awaiting_review
    }
  end

  it "persists pending snapshots in the configured execution store" do
    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store

      define do
        input :order_total, type: :numeric
        compute :quote_total, depends_on: [:order_total], call: StoredAsyncExecutor
        output :quote_total
      end
    end

    contract = contract_class.new(order_total: 100)
    deferred = contract.result.quote_total
    execution_id = contract.execution.events.execution_id

    expect(deferred).to be_a(Igniter::Runtime::DeferredResult)
    expect(Igniter.execution_store.exist?(execution_id)).to eq(true)
  end

  it "restores stored pending execution and resumes by token" do
    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store

      define do
        input :order_total, type: :numeric
        compute :quote_total, depends_on: [:order_total], call: StoredAsyncExecutor
        compute :gross_total, depends_on: [:quote_total] do |quote_total:|
          quote_total * 1.2
        end
        output :gross_total
      end
    end

    original = contract_class.new(order_total: 100)
    original.result.gross_total
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    expect(restored.result.pending?).to eq(true)

    restored.execution.resume_by_token("stored-100", value: 150)

    expect(restored.result.gross_total).to eq(180.0)
    expect(Igniter.execution_store.exist?(execution_id)).to eq(false)
  end

  it "resumes store-backed agent sessions through the class API" do
    trace = pending_agent_trace
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        compute :final_answer, depends_on: :approval do |approval:|
          "approved: #{approval}"
        end
        output :final_answer
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.final_answer
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    session = restored.execution.agent_sessions.first

    resumed = contract_class.resume_agent_session_from_store(execution_id, session: session, value: "ok")

    expect(resumed.result.final_answer).to eq("approved: ok")
    expect(Igniter.execution_store.exist?(execution_id)).to eq(false)
  end

  it "continues store-backed agent sessions before final completion" do
    trace = pending_agent_trace
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        compute :final_answer, depends_on: :approval do |approval:|
          "approved: #{approval}"
        end
        output :final_answer
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.final_answer
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    session = restored.execution.agent_sessions.first

    continued = contract_class.continue_agent_session_from_store(
      execution_id,
      session: session,
      payload: { prompt: "Need human approval" },
      trace: trace.merge(reason: :awaiting_human_reply)
    )

    continued_session = continued.execution.agent_sessions.first
    expect(continued.result.pending?).to be true
    expect(continued_session.turn).to eq(2)
    expect(continued_session.phase).to eq(:waiting)
    expect(continued_session.reply_mode).to eq(:deferred)
    expect(continued_session.last_request).to include(
      turn: 2,
      kind: :request,
      reply_mode: :deferred,
      payload: { prompt: "Need human approval" }
    )
    expect(Igniter.execution_store.exist?(execution_id)).to eq(true)

    resumed = contract_class.resume_agent_session_from_store(execution_id, session: continued_session, value: "ok")

    expect(resumed.result.final_answer).to eq("approved: ok")
    expect(resumed.diagnostics.to_h.dig(:agents, :entries, 0, :agent_session, :last_reply)).to include(
      turn: 3,
      kind: :reply,
      reply_mode: :deferred,
      payload: { value: "ok" }
    )
    expect(Igniter.execution_store.exist?(execution_id)).to eq(false)
  end

  it "exposes remote-owned agent session query and summary directly from store" do
    trace = pending_agent_trace.merge(
      route: {
        routing_mode: :static,
        remote: true,
        url: "http://agents:4567"
      }
    )

    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            reply_mode: node.reply_mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace,
            ownership: :remote,
            owner_url: "http://agents:4567",
            delivery_route: { routing_mode: :static, remote: true, url: "http://agents:4567" }
          }
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        output :approval
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.approval
    execution_id = original.execution.events.execution_id

    query = contract_class.agent_session_query_from_store(execution_id)
    session = query.first

    expect(session).to have_attributes(
      token: session.token,
      ownership: :remote,
      owner_url: "http://agents:4567",
      reply_mode: :deferred,
      phase: :waiting
    )
    expect(session.delivery_route).to include(routing_mode: :static, remote: true, url: "http://agents:4567")
    expect(session.lifecycle).to include(
      state: :waiting,
      ownership: :remote,
      routed: true,
      interactive: false,
      terminal: false,
      continuable: true
    )
    expect(query.ownership(:remote).lifecycle_state(:waiting).routed.count).to eq(1)

    expect(contract_class.agent_session_summary_from_store(execution_id)).to include(
      total: 1,
      by_ownership: { remote: 1 },
      by_lifecycle_state: { waiting: 1 },
      interactive: 0,
      terminal: 0,
      continuable: 1,
      routed: 1
    )
  end

  it "restores streaming agent results with accumulated chunks from store" do
    trace = pending_agent_trace.merge(outcome: :streaming)
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :stream },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            reply_mode: node.reply_mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :summary, via: :writer, message: :summarize, reply: :stream, inputs: { name: :name }
        output :summary
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.summary
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    expect(restored.result.summary).to be_a(Igniter::Runtime::StreamResult)

    session = restored.execution.agent_sessions.first
    expect(session.interaction_contract.to_h).to include(
      mode: :call,
      routing_mode: :local,
      reply: :stream,
      finalizer: :join,
      tool_loop_policy: :complete,
      session_policy: :interactive
    )
    continued = contract_class.continue_agent_session_from_store(
      execution_id,
      session: session,
      payload: {},
      reply: { turn: 2, kind: :reply, name: :summarize, source: :agent, payload: { chunk: "Hello" } },
      phase: :streaming
    )

    stream_value = continued.result.summary

    expect(stream_value).to be_a(Igniter::Runtime::StreamResult)
    expect(stream_value.chunks).to eq(["Hello"])
    expect(stream_value.events).to eq(
      [
        {
          turn: 2,
          source: :agent,
          message_name: :summarize,
          type: :chunk,
          chunk: "Hello"
        }
      ]
    )
    expect(stream_value.phase).to eq(:streaming)
    expect(Igniter.execution_store.exist?(execution_id)).to eq(true)
  end

  it "restores typed stream events from store and keeps chunk views derived" do
    trace = pending_agent_trace.merge(outcome: :streaming)
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :stream },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            reply_mode: node.reply_mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :summary, via: :writer, message: :summarize, reply: :stream, finalizer: :events, inputs: { name: :name }
        output :summary
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.summary
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    session = restored.execution.agent_sessions.first

    continued = contract_class.continue_agent_session_from_store(
      execution_id,
      session: session,
      payload: {},
      reply: {
        turn: 2,
        kind: :reply,
        name: :summarize,
        source: :agent,
        payload: {
          events: [
            { type: :status, status: "thinking" },
            { type: :chunk, chunk: "Hello" }
          ]
        }
      },
      phase: :streaming
    )

    stream_value = continued.result.summary

    expect(stream_value.events).to eq(
      [
        {
          turn: 2,
          source: :agent,
          message_name: :summarize,
          type: :status,
          status: "thinking"
        },
        {
          turn: 2,
          source: :agent,
          message_name: :summarize,
          type: :chunk,
          chunk: "Hello"
        }
      ]
    )
    expect(stream_value.chunks).to eq(["Hello"])

    resumed = contract_class.resume_agent_session_from_store(execution_id, session: continued.execution.agent_sessions.first)

    expect(resumed.result.summary).to eq(
      [
        {
          turn: 2,
          source: :agent,
          message_name: :summarize,
          type: :status,
          status: "thinking"
        },
        {
          turn: 2,
          source: :agent,
          message_name: :summarize,
          type: :chunk,
          chunk: "Hello"
        }
      ]
    )
  end

  it "auto-finalizes streaming sessions from store when no explicit value is provided" do
    trace = pending_agent_trace.merge(outcome: :streaming)
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :stream },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            reply_mode: node.reply_mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :summary, via: :writer, message: :summarize, reply: :stream, inputs: { name: :name }
        output :summary
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.summary
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    session = restored.execution.agent_sessions.first

    contract_class.continue_agent_session_from_store(
      execution_id,
      session: session,
      payload: {},
      reply: { turn: 2, kind: :reply, name: :summarize, source: :agent, payload: { chunk: "Hello, " } },
      phase: :streaming
    )
    continued = contract_class.continue_agent_session_from_store(
      execution_id,
      session: session.token,
      payload: {},
      reply: { turn: 3, kind: :reply, name: :summarize, source: :agent, payload: { chunk: "Alice" } },
      phase: :streaming
    )

    resumed = contract_class.resume_agent_session_from_store(execution_id, session: continued.execution.agent_sessions.first)

    expect(resumed.result.summary).to eq("Hello, Alice")
    expect(Igniter.execution_store.exist?(execution_id)).to eq(false)
  end

  it "blocks store-backed auto-finalization while the tool loop is open" do
    trace = pending_agent_trace.merge(outcome: :streaming)
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :stream },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            reply_mode: node.reply_mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :summary, via: :writer, message: :summarize, reply: :stream, finalizer: :events, inputs: { name: :name }
        output :summary
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.summary
    execution_id = original.execution.events.execution_id

    restored = contract_class.restore_from_store(execution_id)
    session = restored.execution.agent_sessions.first

    contract_class.continue_agent_session_from_store(
      execution_id,
      session: session,
      payload: {},
      reply: {
        turn: 2,
        kind: :reply,
        name: :summarize,
        source: :agent,
        payload: {
          events: [
            Igniter::Runtime::AgentSession.tool_call_event(name: :search, arguments: { q: "Alice" }, call_id: "search-1")
          ]
        }
      },
      phase: :streaming
    )

    expect do
      contract_class.resume_agent_session_from_store(execution_id, session: session.token)
    end.to raise_error(Igniter::ResolutionError, /cannot auto-finalize while tool loop is :open/)
    expect(Igniter.execution_store.exist?(execution_id)).to eq(true)
  end

  it "exposes orchestration overview directly from store" do
    trace = pending_agent_trace
    agent_adapter = Class.new do
      define_method(:call) do |node:, **|
        {
          status: :pending,
          payload: { queue: :review },
          agent_trace: trace,
          session: {
            node_name: node.name,
            node_path: node.path,
            agent_name: node.agent_name,
            message_name: node.message_name,
            mode: node.mode,
            waiting_on: node.name,
            source_node: node.name,
            trace: trace
          }
        }
      end

      define_method(:cast) do |**|
        raise "unexpected cast"
      end
    end.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :store, agent_adapter: agent_adapter

      define do
        input :name
        agent :approval, via: :reviewer, message: :review, inputs: { name: :name }
        output :approval
      end
    end

    original = contract_class.new(name: "Alice")
    original.result.approval
    execution_id = original.execution.events.execution_id

    overview = contract_class.orchestration_overview_from_store(execution_id)

    expect(contract_class.orchestration_summary_from_store(execution_id)).to eq(overview[:summary])
    expect(contract_class.orchestration_transition_summary_from_store(execution_id)).to eq(overview[:transitions][:summary])
    expect(overview[:summary]).to include(
      total: 1,
      attention_required: 1,
      with_session: 1,
      deferred_calls: 1,
      by_action: { await_deferred_reply: 1 },
      by_runtime_status: { pending_session: 1 },
      by_runtime_state: { awaiting_reply: 1 },
      by_runtime_state_class: { session: 1 },
      by_session_lifecycle_state: { waiting: 1 },
      by_ownership: { local: 1 }
    )
    expect(overview[:transitions]).to include(
      summary: include(
        total: 2,
        by_node: { approval: 2 },
        by_action: { await_deferred_reply: 2 },
        by_state: { running: 1, awaiting_reply: 1 },
        by_state_class: { active: 1, session: 1 }
      ),
      transitions: contain_exactly(
        include(node: :approval, action: :await_deferred_reply, event: :node_started, state: :running, state_class: :active),
        include(node: :approval, action: :await_deferred_reply, event: :node_pending, state: :awaiting_reply, state_class: :session)
      )
    )
    expect(overview[:records]).to contain_exactly(
      include(
        node: :approval,
        action: :await_deferred_reply,
        interaction: :deferred_call,
        runtime_status: :pending_session,
        runtime_state: :awaiting_reply,
        runtime_state_class: :session,
        runtime_terminal: false,
        latest_runtime_transition: include(state: :awaiting_reply, state_class: :session),
        session_lifecycle_state: :waiting,
        ownership: :local,
        waiting_on: :approval
      )
    )
  end
end
