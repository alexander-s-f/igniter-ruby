# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter introspection" do
  let(:contract_class) do
    Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric
        input :country, type: :string

        compute :vat_rate, depends_on: [:country] do |country:|
          country == "UA" ? 0.2 : 0.0
        end

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end

        output :gross_total
      end
    end
  end

  it "formats compiled graph as text" do
    text = contract_class.graph.to_text

    expect(text).to include("Graph AnonymousContract")
    expect(text).to include("input order_total")
    expect(text).to include("compute gross_total depends_on=order_total,vat_rate callable=proc")
    expect(text).to include("output.gross_total -> gross_total")
  end

  it "formats compiled graph as mermaid" do
    mermaid = contract_class.graph.to_mermaid

    expect(mermaid).to include("graph TD")
    expect(mermaid).to include('node_order_total["input: order_total"]')
    expect(mermaid).to include('node_vat_rate --> node_gross_total')
    expect(mermaid).to include('node_gross_total["compute: gross_total\nproc"]')
    expect(mermaid).to include('node_gross_total --> output_gross_total')
  end

  it "returns normalized runtime states" do
    contract = contract_class.new(order_total: 100, country: "UA")
    contract.result.gross_total

    states = contract.result.states

    expect(states[:gross_total]).to include(
      id: contract.execution.compiled_graph.fetch_node(:gross_total).id,
      path: "gross_total",
      kind: :compute,
      status: :succeeded,
      value: 120.0
    )
  end

  it "includes invalidation details in runtime states" do
    contract = contract_class.new(order_total: 100, country: "UA")
    contract.result.gross_total
    contract.update_inputs(order_total: 150)

    states = contract.execution.states

    expect(states[:gross_total][:invalidated_by]).to eq(
      node_id: contract.execution.compiled_graph.fetch_node(:order_total).id,
      node_name: :order_total,
      node_path: "order_total"
    )
  end

  it "explains output dependency resolution" do
    contract = contract_class.new(order_total: 100, country: "UA")

    explanation = contract.result.explain(:gross_total)

    expect(explanation[:output_id]).to eq(contract.execution.compiled_graph.fetch_output(:gross_total).id)
    expect(explanation[:output]).to eq(:gross_total)
    expect(explanation[:source_id]).to eq(contract.execution.compiled_graph.fetch_node(:gross_total).id)
    expect(explanation[:source]).to eq(:gross_total)
    expect(explanation[:dependencies].dig(:dependencies, 0, :name)).to eq(:order_total)
    expect(explanation[:dependencies].dig(:dependencies, 1, :name)).to eq(:vat_rate)
  end

  it "exposes runtime explain API on execution" do
    contract = contract_class.new(order_total: 100, country: "UA")
    contract.result.gross_total

    explanation = contract.execution.explain_output(:gross_total)

    expect(explanation[:dependencies][:status]).to eq(:succeeded)
    expect(explanation[:dependencies][:value]).to eq(120.0)
  end

  it "builds a machine-readable execution plan with ready and blocked nodes" do
    contract = contract_class.new(order_total: 100, country: "UA")

    plan = contract.execution.plan

    expect(plan[:targets]).to eq([:gross_total])
    expect(plan[:ready]).to include(:order_total, :country, :vat_rate)
    expect(plan[:blocked]).to include(:gross_total)
    expect(plan[:nodes][:gross_total][:waiting_on]).to include(:vat_rate)
  end

  it "preserves scoped paths in plans and graph formatting" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :country, type: :string

        scope :taxes do
          compute :vat_rate, with: :country do |country:|
            country == "UA" ? 0.2 : 0.0
          end
        end

        output :vat_rate
      end
    end

    contract = contract_class.new(country: "UA")

    expect(contract.class.graph.to_text).to include("taxes.vat_rate")
    expect(contract.execution.plan[:nodes][:vat_rate][:path]).to eq("taxes.vat_rate")
  end

  it "explains the execution plan without resolving compute nodes" do
    calls = 0

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total, type: :numeric
        input :country, type: :string

        compute :vat_rate, depends_on: [:country] do |country:|
          calls += 1
          country == "UA" ? 0.2 : 0.0
        end

        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:, vat_rate:|
          calls += 1
          order_total * (1 + vat_rate)
        end

        output :gross_total
      end
    end

    contract = contract_class.new(order_total: 100, country: "UA")

    explanation = contract.explain_plan

    expect(explanation).to include("Plan AnonymousContract")
    expect(explanation).to include("Targets: gross_total")
    expect(explanation).to include("Ready: order_total,country,vat_rate")
    expect(explanation).to include("Blocked: gross_total")
    expect(explanation).to include("compute gross_total")
    expect(explanation).to include("waiting_on=vat_rate")
    expect(calls).to eq(0)
    expect(contract.events).to be_empty
  end

  it "exposes agent execution profiles in plan and explain output" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :name, type: :string

        agent :interactive_summary,
              via: :writer,
              message: :summarize,
              reply: :stream,
              inputs: { name: :name }

        agent :manual_summary,
              via: :writer,
              message: :summarize,
              reply: :stream,
              session_policy: :manual,
              finalizer: :events,
              inputs: { name: :name }

        agent :single_turn_summary,
              via: :writer,
              message: :summarize,
              reply: :stream,
              session_policy: :single_turn,
              tool_loop_policy: :resolved,
              inputs: { name: :name }

        agent :approval,
              via: :reviewer,
              message: :review,
              inputs: { name: :name }

        output :interactive_summary
        output :manual_summary
        output :single_turn_summary
        output :approval
      end
    end

    contract = contract_class.new(name: "Alice")

    plan = contract.execution.plan

    expect(plan[:agent_profiles]).to eq(
      total: 4,
      interactive: 1,
      manual: 1,
      single_turn: 1,
      streaming: 3,
      deferred: 1
    )
    expect(plan[:orchestration]).to include(
      total: 4,
      attention_required: 3,
      resumable: 4,
      interactive_sessions: 1,
      manual_sessions: 1,
      single_turn_sessions: 1,
      deferred_calls: 1,
      single_reply_calls: 0,
      delivery_only: 0,
      attention_nodes: %i[interactive_summary manual_summary approval],
      by_action: {
        open_interactive_session: 1,
        require_manual_completion: 1,
        await_single_turn_completion: 1,
        await_deferred_reply: 1
      }
    )
    expect(contract.orchestration_plan).to eq(plan[:orchestration])
    expect(plan[:orchestration][:actions]).to contain_exactly(
      include(
        id: "agent_orchestration:open_interactive_session:interactive_summary",
        action: :open_interactive_session,
        node: :interactive_summary,
        interaction: :interactive_session,
        reason: :interactive_session,
        attention_required: true,
        resumable: true
      ),
      include(
        id: "agent_orchestration:require_manual_completion:manual_summary",
        action: :require_manual_completion,
        node: :manual_summary,
        interaction: :manual_session,
        reason: :manual_session,
        attention_required: true,
        resumable: true
      ),
      include(
        id: "agent_orchestration:await_single_turn_completion:single_turn_summary",
        action: :await_single_turn_completion,
        node: :single_turn_summary,
        interaction: :single_turn_session,
        reason: :single_turn_session,
        attention_required: false,
        resumable: true
      ),
      include(
        id: "agent_orchestration:await_deferred_reply:approval",
        action: :await_deferred_reply,
        node: :approval,
        interaction: :deferred_call,
        reason: :deferred_call,
        attention_required: true,
        resumable: true
      )
    )

    expect(plan[:nodes][:interactive_summary]).to include(
      kind: :agent,
      via: :writer,
      message: :summarize,
      mode: :call,
      reply_mode: :stream,
      finalizer: :join,
      session_policy: :interactive,
      tool_loop_policy: :complete
    )
    expect(plan[:nodes][:interactive_summary][:execution_profile]).to include(
      delivery: :call,
      streaming: true,
      deferred: false,
      resumable: true,
      interactive: true,
      manual_completion: false,
      single_turn: false
    )
    expect(plan[:nodes][:interactive_summary][:orchestration]).to include(
      node: :interactive_summary,
      interaction: :interactive_session,
      attention_required: true,
      resumable: true,
      allows_continuation: true,
      requires_explicit_completion: false,
      auto_finalization: :complete
    )
    expect(plan[:nodes][:interactive_summary][:orchestration][:guidance]).to include("multi-turn continuation")

    expect(plan[:nodes][:manual_summary]).to include(
      session_policy: :manual,
      tool_loop_policy: :complete,
      finalizer: :events
    )
    expect(plan[:nodes][:manual_summary][:execution_profile]).to include(
      streaming: true,
      manual_completion: true,
      interactive: false,
      single_turn: false
    )
    expect(plan[:nodes][:manual_summary][:orchestration]).to include(
      node: :manual_summary,
      interaction: :manual_session,
      attention_required: true,
      resumable: true,
      allows_continuation: true,
      requires_explicit_completion: true,
      auto_finalization: :disabled
    )

    expect(plan[:nodes][:single_turn_summary]).to include(
      session_policy: :single_turn,
      tool_loop_policy: :resolved,
      finalizer: :join
    )
    expect(plan[:nodes][:single_turn_summary][:execution_profile]).to include(
      streaming: true,
      single_turn: true,
      interactive: false,
      manual_completion: false
    )
    expect(plan[:nodes][:single_turn_summary][:orchestration]).to include(
      node: :single_turn_summary,
      interaction: :single_turn_session,
      attention_required: false,
      resumable: true,
      allows_continuation: false,
      requires_explicit_completion: false,
      auto_finalization: :resolved
    )

    expect(plan[:nodes][:approval]).to include(
      reply_mode: :deferred,
      session_policy: nil,
      tool_loop_policy: nil,
      finalizer: nil
    )
    expect(plan[:nodes][:approval][:execution_profile]).to include(
      delivery: :call,
      streaming: false,
      deferred: true,
      resumable: true,
      interactive: false,
      manual_completion: false,
      single_turn: false
    )
    expect(plan[:nodes][:approval][:orchestration]).to include(
      node: :approval,
      interaction: :deferred_call,
      attention_required: true,
      resumable: true,
      allows_continuation: false,
      requires_explicit_completion: false,
      auto_finalization: :not_applicable
    )

    explanation = contract.explain_plan

    expect(explanation).to include("Agents: total=4, interactive=1, manual=1, single_turn=1, streaming=3, deferred=1")
    expect(explanation).to include("Orchestration: attention_required=3, resumable=4, interactive_sessions=1, manual_sessions=1, single_turn_sessions=1, deferred_calls=1, single_reply_calls=0, delivery_only=0")
    expect(explanation).to include("Attention Nodes: interactive_summary,manual_summary,approval")
    expect(explanation).to include("Orchestration Actions: interactive_summary(open_interactive_session), manual_summary(require_manual_completion), single_turn_summary(await_single_turn_completion), approval(await_deferred_reply)")
    expect(explanation).to include("agent interactive_summary")
    expect(explanation).to include("via=:writer")
    expect(explanation).to include("message=:summarize")
    expect(explanation).to include("reply=stream")
    expect(explanation).to include("session_policy=interactive")
    expect(explanation).to include("tool_loop_policy=complete")
    expect(explanation).to include("finalizer=:join")
    expect(explanation).to include("orchestration=interactive_session")
    expect(explanation).to include('guidance="streaming session; multi-turn continuation is allowed"')
    expect(explanation).to include("attention_required=true")
    expect(explanation).to include("resumable=true")
    expect(explanation).to include("allows_continuation=true")
    expect(explanation).to include("auto_finalization=complete")
    expect(explanation).to include("agent manual_summary")
    expect(explanation).to include("session_policy=manual")
    expect(explanation).to include("finalizer=:events")
    expect(explanation).to include("orchestration=manual_session")
    expect(explanation).to include("requires_explicit_completion=true")
    expect(explanation).to include("auto_finalization=disabled")
    expect(explanation).to include("agent single_turn_summary")
    expect(explanation).to include("session_policy=single_turn")
    expect(explanation).to include("tool_loop_policy=resolved")
    expect(explanation).to include("orchestration=single_turn_session")
    expect(explanation).to include("auto_finalization=resolved")
    expect(explanation).to include("agent approval")
    expect(explanation).to include("reply=deferred")
    expect(explanation).to include("orchestration=deferred_call")
  end
end
