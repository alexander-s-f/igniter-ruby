# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"
require "igniter/agent"

RSpec.describe "Igniter diagnostics" do
  let(:contract_class) do
    Class.new(Igniter::Contract) do
      define do
        input :order_total
        input :country

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

  it "builds a structured diagnostics report" do
    contract = contract_class.new(order_total: 100, country: "UA")

    report = contract.diagnostics.to_h

    expect(report).to include(
      graph: "AnonymousContract",
      execution_id: contract.execution.events.execution_id,
      status: :succeeded,
      outputs: { gross_total: 120.0 }
    )
    expect(report[:nodes]).to include(total: 4, succeeded: 4, failed: 0, stale: 0)
    expect(report[:events]).to include(latest_type: :execution_finished)
  end

  it "formats diagnostics as text and markdown" do
    contract = contract_class.new(order_total: 100, country: "UA")

    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(text).to include("Diagnostics AnonymousContract")
    expect(text).to include("Status: succeeded")
    expect(markdown).to include("# Diagnostics AnonymousContract")
    expect(markdown).to include("- Status: `succeeded`")
  end

  it "surfaces orchestration summaries and actions for agent-backed workflows" do
    previous_adapter = Igniter::Runtime.agent_adapter
    Igniter::Runtime.activate_agent_adapter!
    Igniter::Registry.clear
    writer_ref = nil
    reviewer_ref = nil

    writer_class = Class.new(Igniter::Agent) do
      on :summarize do |payload:, **|
        raise Igniter::PendingDependencyError.new("continue", token: "writer-session", source_node: :summary)
      end
    end

    reviewer_class = Class.new(Igniter::Agent) do
      on :review do |payload:, **|
        raise Igniter::PendingDependencyError.new("wait", token: "review-session", source_node: :approval)
      end
    end

    writer_ref = writer_class.start(name: :writer)
    reviewer_ref = reviewer_class.start(name: :reviewer)

    agent_contract = Class.new(Igniter::Contract) do
      define do
        input :name

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

        agent :approval,
              via: :reviewer,
              message: :review,
              inputs: { name: :name }

        output :interactive_summary
        output :manual_summary
        output :approval
      end
    end

    contract = agent_contract.new(name: "Alice")

    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:orchestration]).to include(
      total: 3,
      attention_required: 3,
      resumable: 3,
      interactive_sessions: 1,
      manual_sessions: 1,
      single_turn_sessions: 0,
      deferred_calls: 1,
      attention_nodes: %i[interactive_summary manual_summary approval],
      by_action: {
        open_interactive_session: 1,
        require_manual_completion: 1,
        await_deferred_reply: 1
      }
    )
    expect(report[:orchestration][:actions]).to contain_exactly(
      include(action: :open_interactive_session, node: :interactive_summary, interaction: :interactive_session),
      include(action: :require_manual_completion, node: :manual_summary, interaction: :manual_session),
      include(action: :await_deferred_reply, node: :approval, interaction: :deferred_call)
    )
    expect(text).to include("Orchestration: total=3, attention_required=3, resumable=3, interactive_sessions=1, manual_sessions=1, single_turn_sessions=0, deferred_calls=1, actions=3")
    expect(text).to include("Orchestration Actions: interactive_summary(open_interactive_session reason=interactive_session), manual_summary(require_manual_completion reason=manual_session), approval(await_deferred_reply reason=deferred_call)")
    expect(markdown).to include("## Orchestration")
    expect(markdown).to include("- Summary: total=3, attention_required=3, resumable=3, interactive_sessions=1, manual_sessions=1, single_turn_sessions=0, deferred_calls=1, actions=3")
    expect(markdown).to include("`open_interactive_session`(interactive_summary)")
    expect(markdown).to include("`manual_summary` `require_manual_completion`")
  ensure
    writer_ref&.stop
    reviewer_ref&.stop
    Igniter::Registry.clear
    Igniter::Runtime.agent_adapter = previous_adapter
  end

  it "surfaces cluster identity and trust in diagnostics when mesh is configured" do
    Igniter::Cluster::Mesh.reset!
    identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "diag-seed")
    trust_store = Igniter::Cluster::Trust::TrustStore.new(
      [
        { node_id: "diag-seed", public_key: identity.public_key_pem, label: "self" }
      ]
    )

    peer_identity = Igniter::Cluster::Identity::NodeIdentity.generate(node_id: "diag-edge")
    peer_manifest = Igniter::Cluster::Identity::Manifest.build(
      identity: peer_identity,
      peer_name: "diag-edge",
      url: "http://edge:4567",
      capabilities: [:speech_io],
      tags: [:edge],
      metadata: { region: "local" },
      contracts: []
    )

    Igniter::Cluster::Mesh.configure do |c|
      c.peer_name = "diag-seed"
      c.identity = identity
      c.trust_store = trust_store
      c.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(
          name: "diag-edge",
          url: "http://edge:4567",
          capabilities: [:speech_io],
          metadata: Igniter::Cluster::Mesh::PeerIdentityEnvelope.build(
            source: peer_manifest.to_h,
            trust_store: trust_store
          )[:metadata]
        )
      )
    end
    Igniter::Cluster::Mesh.config.governance_trail.record(
      :trust_admission_applied,
      source: :spec,
      payload: { peer_name: "diag-edge", node_id: "diag-edge" }
    )

    contract = contract_class.new(order_total: 100, country: "UA")
    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:cluster_identity]).to include(
      local: include(node_id: "diag-seed"),
      counts: include(peers: 1, unknown: 1, trusted: 0, invalid: 0, attested: 1, attested_trusted: 0)
    )
    expect(report[:cluster_identity][:peers]).to contain_exactly(
      include(
        name: "diag-edge",
        trust: include(status: :unknown),
        capabilities_attestation: include(
          trust: include(status: :unknown)
        )
      )
    )
    expect(report[:cluster_governance]).to include(
      total: 1,
      latest_type: :trust_admission_applied,
      by_type: include(trust_admission_applied: 1),
      persistence: include(enabled: false),
      checkpoint: include(
        node_id: "diag-seed",
        trust: include(status: :trusted, trusted: true),
        crest_digest: kind_of(String)
      )
    )
    expect(text).to include("Cluster Identity: local=diag-seed")
    expect(text).to include("Cluster Governance: total=1 latest=trust_admission_applied persisted=false retain=all archived=0 checkpoint=trusted")
    expect(text).to include("attested=1")
    expect(markdown).to include("- Cluster Identity: local=`diag-seed`")
    expect(markdown).to include("- Cluster Governance: total=1 latest=trust_admission_applied persisted=false retain=all archived=0 checkpoint=trusted")
    expect(markdown).to include("## Cluster Identity")
    expect(markdown).to include("## Cluster Governance")
    expect(markdown).to include("- Checkpoint: node_id=`diag-seed` trust=`trusted`")
  ensure
    Igniter::Cluster::Mesh.reset!
  end

  it "surfaces failed nodes in the diagnostics report" do
    failing_contract = Class.new(Igniter::Contract) do
      define do
        input :order_total

        compute :gross_total, depends_on: [:order_total] do |order_total:|
          raise "boom #{order_total}"
        end

        output :gross_total
      end
    end

    contract = failing_contract.new(order_total: 100)

    report = contract.diagnostics.to_h
    expect(report[:status]).to eq(:failed)
    expect(report[:nodes][:failed_nodes].first).to include(node_name: :gross_total)
    expect(report[:errors].first[:message]).to include("boom 100")
  end

  it "summarizes collection item failures in diagnostics" do
    child_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_id

        guard :active_technician, with: :technician_id, message: "Technician inactive" do |technician_id:|
          technician_id != 2
        end

        compute :summary, with: %i[technician_id active_technician] do |technician_id:, active_technician:|
          active_technician
          { id: technician_id }
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: child_contract, key: :technician_id, mode: :collect

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1 },
      { technician_id: 2 }
    ])

    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:status]).to eq(:succeeded)
    expect(report[:outputs][:technicians]).to include(
      mode: :collect,
      summary: include(total: 2, succeeded: 1, failed: 1, status: :partial_failure)
    )
    expect(report[:collection_nodes]).to include(
      include(
        node_name: :technicians,
        total: 2,
        succeeded: 1,
        failed: 1,
        status: :partial_failure,
        failed_items: [include(key: 2, message: include("Technician inactive"))]
      )
    )
    expect(text).to include("Collections: technicians total=2 succeeded=1 failed=1 status=partial_failure")
    expect(text).to include("failed_items=2(")
    expect(markdown).to include("## Collections")
    expect(markdown).to include("`technicians`: total=2, succeeded=1, failed=1, status=partial_failure")
    expect(markdown).to include("`technicians[2]` failed: Technician inactive")
  end

  it "formats nested result and collection outputs compactly in diagnostics text" do
    child_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: Class.new(Igniter::Contract) {
          define do
            input :technician_id

            compute :summary, with: :technician_id do |technician_id:|
              { id: technician_id }
            end

            output :summary
          end
        }, key: :technician_id, mode: :collect

        output :technicians
      end
    end

    parent_contract = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        compose :batch, contract: child_contract, inputs: {
          technician_inputs: :technician_inputs
        }

        output :batch
      end
    end

    contract = parent_contract.new(technician_inputs: [{ technician_id: 1 }, { technician_id: 2 }])

    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(text).to include('batch={technicians: {mode=:collect, total=2, succeeded=2, failed=0, status=:succeeded, keys=[1, 2], failed_keys=[]}}')
    expect(markdown).to include("- Outputs: batch={technicians: {mode=:collect, total=2, succeeded=2, failed=0, status=:succeeded, keys=[1, 2], failed_keys=[]}}")
  end

  it "supports output presenters for compact diagnostics formatting" do
    contract_class = Class.new(Igniter::Contract) do
      define do
        input :rows, type: :array
        output :rows
      end

      present :rows do |value:, **|
        {
          total: value.size,
          company_ids: value.map { |row| row[:company_id] }.uniq
        }
      end
    end

    contract = contract_class.new(rows: [
      { company_id: "1", location_id: "746" },
      { company_id: "2", location_id: "1666" }
    ])

    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:outputs][:rows]).to eq([
      { company_id: "1", location_id: "746" },
      { company_id: "2", location_id: "1666" }
    ])
    expect(text).to include('rows={total: 2, company_ids: ["1", "2"]}')
    expect(markdown).to include('- Outputs: rows={total: 2, company_ids: ["1", "2"]}')
  end

  it "surfaces contract capability footprint in diagnostics" do
    pure_executor = Class.new(Igniter::Executor) do
      pure

      def call(order_total:) = order_total * 2
    end

    network_executor = Class.new(Igniter::Executor) do
      capabilities :network, :external_api

      def call(order_total:) = order_total
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total
        compute :doubled_total, depends_on: :order_total, call: pure_executor
        compute :quoted_total, depends_on: :order_total, call: network_executor
        output :doubled_total
        output :quoted_total
      end
    end

    contract = contract_class.new(order_total: 100)

    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:capabilities]).to include(
      total_nodes: 2,
      pure_nodes: 1,
      impure_nodes: 1,
      unique_capabilities: %i[external_api network pure]
    )
    expect(report[:capabilities][:by_capability]).to include(
      pure: 1,
      network: 1,
      external_api: 1
    )
    expect(report[:capabilities][:nodes]).to contain_exactly(
      include(node_name: :doubled_total, capabilities: [:pure], pure: true),
      include(node_name: :quoted_total, capabilities: %i[external_api network], pure: false)
    )
    expect(text).to include("Capabilities: nodes=2, pure=1, impure=1, unique=external_api|network|pure")
    expect(markdown).to include("- Capabilities: nodes=2, pure=1, impure=1, unique=external_api|network|pure")
    expect(markdown).to include("## Capabilities")
    expect(markdown).to include("`doubled_total` executor=")
    expect(markdown).to include("capabilities=pure pure=true")
    expect(markdown).to include("`quoted_total` executor=")
    expect(markdown).to include("capabilities=external_api, network pure=false")
  end

  it "surfaces policy-aware capability decisions in diagnostics" do
    pure_executor = Class.new(Igniter::Executor) do
      pure

      def call(order_total:) = order_total * 2
    end

    denied_executor = Class.new(Igniter::Executor) do
      capabilities :network, :external_api

      def call(order_total:) = order_total
    end

    risky_executor = Class.new(Igniter::Executor) do
      capabilities :custom_probe

      def call(order_total:) = order_total
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :order_total
        compute :doubled_total, depends_on: :order_total, call: pure_executor
        compute :quoted_total, depends_on: :order_total, call: denied_executor
        compute :probed_total, depends_on: :order_total, call: risky_executor
        output :doubled_total
      end
    end

    Igniter::Capabilities.policy = Igniter::Capabilities::Policy.new(
      denied: [:network],
      on_unknown: :warn
    )

    contract = contract_class.new(order_total: 100)

    report = contract.diagnostics.to_h
    text = contract.diagnostics_text
    markdown = contract.diagnostics_markdown

    expect(report[:capabilities][:policy]).to include(
      configured: true,
      denied_capabilities: [:network],
      on_unknown: :warn,
      allowed_nodes: 1,
      denied_nodes: 1,
      risky_nodes: 1
    )
    expect(report[:capabilities][:policy][:nodes]).to contain_exactly(
      include(node_name: :doubled_total, status: :allowed, allowed_capabilities: [:pure]),
      include(node_name: :quoted_total, status: :denied, denied_capabilities: [:network], allowed_capabilities: [:external_api]),
      include(node_name: :probed_total, status: :risky, risky_capabilities: [:custom_probe])
    )
    expect(text).to include("Capability Policy: configured=true, allowed=1, denied=1, risky=1, on_unknown=warn")
    expect(markdown).to include("- Capability Policy: configured=true, allowed=1, denied=1, risky=1, on_unknown=warn")
    expect(markdown).to include("## Capability Policy")
    expect(markdown).to include("`quoted_total` status=denied")
    expect(markdown).to include("denied=network")
    expect(markdown).to include("`probed_total` status=risky")
    expect(markdown).to include("risky=custom_probe")
  ensure
    Igniter::Capabilities.policy = nil
  end

  describe "distributed routing traces" do
    let(:pending_trace) do
      {
        routing_mode: :capability,
        query: {
          all_of: [:orders],
          tags: [:linux],
          policy: { permits: [:shell_exec], approvable: [:deploy] },
          decision: { mode: :approval_ok, actions: [:shell_exec] }
        },
        selected_url: nil,
        eligible_count: 0,
        peers: [
          { name: "orders-linux", reasons: [:unreachable] }
        ]
      }
    end

    let(:failed_trace) do
      {
        routing_mode: :pinned,
        peer_name: "audit-node",
        known: true,
        selected_url: "http://audit:4567",
        reachable: false,
        reasons: [:unreachable]
      }
    end

    let(:policy_gate_trace) do
      {
        routing_mode: :capability,
        query: {
          all_of: [:orders],
          policy: { permits: [:shell_exec] },
          decision: { mode: :auto_only, actions: [:shell_exec] }
        },
        selected_url: nil,
        eligible_count: 0,
        matched_count: 0,
        peer_count: 1,
        peers: [
          {
            name: "orders-guarded",
            matched: false,
            reasons: [:query_mismatch],
            match_details: { failed_dimensions: %i[policy decision] }
          }
        ]
      }
    end

    let(:trust_gate_trace) do
      {
        routing_mode: :capability,
        query: {
          all_of: [:orders],
          trust: { identity: :trusted, attestation: :trusted }
        },
        selected_url: nil,
        eligible_count: 0,
        matched_count: 0,
        peer_count: 1,
        peers: [
          {
            name: "orders-unknown",
            matched: false,
            reasons: [:query_mismatch],
            match_details: { failed_dimensions: [:trust] }
          }
        ]
      }
    end

    let(:governance_gate_trace) do
      {
        routing_mode: :capability,
        query: {
          all_of: [:orders],
          governance: {
            trust: :trusted,
            latest_type: :routing_plan_applied,
            blocked_events: { max: 1 }
          }
        },
        selected_url: nil,
        eligible_count: 0,
        matched_count: 0,
        peer_count: 1,
        peers: [
          {
            name: "orders-blocked",
            matched: false,
            reasons: [:query_mismatch],
            match_details: { failed_dimensions: [:governance] }
          }
        ]
      }
    end

    let(:capacity_trace) do
      {
        routing_mode: :capability,
        query: {
          all_of: [:gpu_inference],
          tags: [:cuda]
        },
        selected_url: nil,
        eligible_count: 0,
        matched_count: 0,
        peer_count: 1,
        peers: [
          {
            name: "orders-linux",
            matched: false,
            reasons: [:query_mismatch],
            match_details: { failed_dimensions: %i[capabilities tags] }
          }
        ]
      }
    end

    let(:pending_adapter) do
      trace = pending_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :orders,
            Igniter::Runtime::DeferredResult.build(
              token: "route-order-42",
              payload: { query: { all_of: [:orders] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:orders] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:failed_adapter) do
      trace = failed_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |**|
          raise Igniter::ResolutionError.new(
            "Pinned peer is unreachable",
            context: { routing_trace: @routing_trace }
          )
        end
      end.new(trace)
    end

    let(:policy_gate_adapter) do
      trace = policy_gate_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :orders,
            Igniter::Runtime::DeferredResult.build(
              token: "gate-order-42",
              payload: { query: { all_of: [:orders] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:orders] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:capacity_adapter) do
      trace = capacity_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :gpu_inference,
            Igniter::Runtime::DeferredResult.build(
              token: "capacity-order-42",
              payload: { query: { all_of: [:gpu_inference] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:gpu_inference] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:trust_gate_adapter) do
      trace = trust_gate_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :orders,
            Igniter::Runtime::DeferredResult.build(
              token: "trust-order-42",
              payload: { query: { all_of: [:orders] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:orders] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:governance_gate_adapter) do
      trace = governance_gate_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :orders,
            Igniter::Runtime::DeferredResult.build(
              token: "governance-order-42",
              payload: { query: { all_of: [:orders] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:orders] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:pending_contract_class) do
      adapter = pending_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    let(:failed_contract_class) do
      adapter = failed_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :event
          remote :audit_result, contract: "WriteAudit", node: "http://unused.example", inputs: { event: :event }
          output :audit_result
        end
      end
    end

    let(:policy_gate_contract_class) do
      adapter = policy_gate_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    let(:capacity_contract_class) do
      adapter = capacity_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    let(:trust_gate_contract_class) do
      adapter = trust_gate_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    let(:governance_gate_contract_class) do
      adapter = governance_gate_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    it "surfaces routing traces for pending remote outputs in diagnostics" do
      contract = pending_contract_class.new(order_id: 42)

      report = contract.diagnostics.to_h
      text = contract.diagnostics_text
      markdown = contract.diagnostics_markdown

      expect(report[:status]).to eq(:pending)
      expect(report[:outputs][:order_result]).to include(
        token: "route-order-42",
        routing_trace: pending_trace,
        routing_trace_summary: "mode=capability query={:all_of=>[:orders], :tags=>[:linux], :policy=>{:permits=>[:shell_exec], :approvable=>[:deploy]}, :decision=>{:mode=>:approval_ok, :actions=>[:shell_exec]}} eligible=0 selected=none reasons=unreachable"
      )
      expect(report[:routing]).to include(total: 1, pending: 1, failed: 0)
      expect(report[:routing][:facets]).to include(
        by_status: { pending: 1 },
        by_mode: { capability: 1 },
        by_reason: { unreachable: 1 },
        by_mismatch_dimension: {},
        by_decision_mode: { approval_ok: 1 },
        by_policy_key: { approvable: 1, permits: 1 },
        by_latest_event: { node_pending: 1 },
        by_incident: { peer_unreachable: 1 },
        by_remediation_code: { restore_peer_connectivity: 1 },
        by_plan_action: { refresh_peer_health: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :refresh_peer_health,
          scope: :mesh_health,
          automated: true,
          requires_approval: false,
          params: {},
          sources: [
            include(node_name: :order_result, incident: :peer_unreachable, hint_code: :restore_peer_connectivity)
          ]
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          node_name: :order_result,
          status: :pending,
          token: "route-order-42",
          waiting_on: :order_result,
          routing_trace: pending_trace,
          routing_trace_summary: "mode=capability query={:all_of=>[:orders], :tags=>[:linux], :policy=>{:permits=>[:shell_exec], :approvable=>[:deploy]}, :decision=>{:mode=>:approval_ok, :actions=>[:shell_exec]}} eligible=0 selected=none reasons=unreachable",
          classification: include(
            routing_mode: :capability,
            reasons: [:unreachable],
            decision_mode: :approval_ok,
            decision_actions: [:shell_exec],
            policy_keys: %i[approvable permits],
            latest_event_type: :node_pending,
            incident: :peer_unreachable
          ),
          remediation: [
            include(
              code: :restore_peer_connectivity,
              plan: include(
                action: :refresh_peer_health,
                scope: :mesh_health,
                automated: true,
                requires_approval: false,
                params: {}
              ),
              details: {}
            )
          ],
          events: include(latest_type: :node_pending)
        )
      )
      expect(text).to include("Routing: total=1, pending=1, failed=0, modes=capability=1, reasons=unreachable=1, incidents=peer_unreachable=1, hints=restore_peer_connectivity=1, plans=refresh_peer_health=1")
      expect(text).to include("hints=restore_peer_connectivity")
      expect(text).to include("routing=mode=capability query={:all_of=>[:orders], :tags=>[:linux], :policy=>{:permits=>[:shell_exec], :approvable=>[:deploy]}, :decision=>{:mode=>:approval_ok, :actions=>[:shell_exec]}} eligible=0 selected=none reasons=unreachable")
      expect(markdown).to include("- Routing: total=1, pending=1, failed=0, modes=capability=1, reasons=unreachable=1, incidents=peer_unreachable=1, hints=restore_peer_connectivity=1, plans=refresh_peer_health=1")
      expect(markdown).to include("## Routing")
      expect(markdown).to include("`order_result` `pending`")
      expect(markdown).to include("hints=`restore_peer_connectivity`")
      expect(markdown).to include("mode=capability query={:all_of=>[:orders], :tags=>[:linux], :policy=>{:permits=>[:shell_exec], :approvable=>[:deploy]}, :decision=>{:mode=>:approval_ok, :actions=>[:shell_exec]}} eligible=0 selected=none reasons=unreachable")
    end

    it "surfaces routing traces for failed remote outputs in diagnostics" do
      contract = failed_contract_class.new(event: "created")

      report = contract.diagnostics.to_h
      text = contract.diagnostics_text
      markdown = contract.diagnostics_markdown

      expect(report[:status]).to eq(:failed)
      expect(report[:outputs][:audit_result]).to include(
        status: :failed,
        routing_trace: failed_trace,
        routing_trace_summary: "mode=pinned peer=audit-node selected=http://audit:4567 reachable=false reasons=unreachable"
      )
      expect(report[:outputs][:audit_result][:error]).to include("Pinned peer is unreachable")
      expect(report[:errors].first).to include(
        node_name: :audit_result,
        routing_trace: failed_trace,
        routing_trace_summary: "mode=pinned peer=audit-node selected=http://audit:4567 reachable=false reasons=unreachable"
      )
      expect(report[:routing]).to include(total: 1, pending: 0, failed: 1)
      expect(report[:routing][:facets]).to include(
        by_status: { failed: 1 },
        by_mode: { pinned: 1 },
        by_reason: { unreachable: 1 },
        by_mismatch_dimension: {},
        by_decision_mode: {},
        by_policy_key: {},
        by_latest_event: { node_failed: 1 },
        by_incident: { peer_unreachable: 1 },
        by_remediation_code: { restore_peer_connectivity: 1 },
        by_plan_action: { refresh_peer_health: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :refresh_peer_health,
          scope: :mesh_health,
          automated: true,
          requires_approval: false,
          params: { peer_name: "audit-node", selected_url: "http://audit:4567" },
          sources: [
            include(node_name: :audit_result, incident: :peer_unreachable, hint_code: :restore_peer_connectivity)
          ]
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          node_name: :audit_result,
          status: :failed,
          routing_trace: failed_trace,
          routing_trace_summary: "mode=pinned peer=audit-node selected=http://audit:4567 reachable=false reasons=unreachable",
          classification: include(
            routing_mode: :pinned,
            reasons: [:unreachable],
            latest_event_type: :node_failed,
            incident: :peer_unreachable
          ),
          remediation: [
            include(
              code: :restore_peer_connectivity,
              plan: include(
                action: :refresh_peer_health,
                scope: :mesh_health,
                automated: true,
                requires_approval: false,
                params: { peer_name: "audit-node", selected_url: "http://audit:4567" }
              ),
              details: include(peer_name: "audit-node", selected_url: "http://audit:4567")
            )
          ],
          events: include(latest_type: :node_failed),
          error: include(
            type: "Igniter::ResolutionError",
            message: include("Pinned peer is unreachable")
          )
        )
      )
      expect(text).to include("Routing: total=1, pending=0, failed=1, modes=pinned=1, reasons=unreachable=1, incidents=peer_unreachable=1, hints=restore_peer_connectivity=1, plans=refresh_peer_health=1")
      expect(text).to include("hints=restore_peer_connectivity")
      expect(text).to include("Errors: audit_result=Igniter::ResolutionError")
      expect(markdown).to include("- Routing: total=1, pending=0, failed=1, modes=pinned=1, reasons=unreachable=1, incidents=peer_unreachable=1, hints=restore_peer_connectivity=1, plans=refresh_peer_health=1")
      expect(markdown).to include("## Routing")
      expect(markdown).to include("`audit_result` `failed`")
      expect(markdown).to include("hints=`restore_peer_connectivity`")
      expect(markdown).to include("`mode=pinned peer=audit-node selected=http://audit:4567 reachable=false reasons=unreachable`")
    end

    it "triages policy gates separately from network incidents" do
      contract = policy_gate_contract_class.new(order_id: 42)

      report = contract.diagnostics.to_h

      expect(report[:routing][:facets]).to include(
        by_reason: { query_mismatch: 1 },
        by_mismatch_dimension: { decision: 1, policy: 1 },
        by_decision_mode: { auto_only: 1 },
        by_policy_key: { permits: 1 },
        by_latest_event: { node_pending: 1 },
        by_incident: { policy_gate: 1 },
        by_remediation_code: { adjust_policy_requirements: 1, request_approval_path: 1 },
        by_plan_action: { find_policy_compatible_peer: 1, retry_with_approval: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :retry_with_approval,
          scope: :routing_decision,
          automated: false,
          requires_approval: true,
          params: { mode: :approval_ok, actions: [:shell_exec] }
        ),
        include(
          action: :find_policy_compatible_peer,
          scope: :routing_policy,
          automated: true,
          requires_approval: false,
          params: { policy_keys: [:permits] }
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          classification: include(
            mismatch_dimensions: %i[decision policy],
            latest_event_type: :node_pending,
            incident: :policy_gate
          ),
          remediation: contain_exactly(
            include(
              code: :request_approval_path,
              details: include(decision_mode: :auto_only, actions: [:shell_exec]),
              plan: include(action: :retry_with_approval, scope: :routing_decision, automated: false, requires_approval: true)
            ),
            include(
              code: :adjust_policy_requirements,
              details: include(policy_keys: [:permits]),
              plan: include(action: :find_policy_compatible_peer, scope: :routing_policy, automated: true, requires_approval: false)
            )
          ),
          events: include(latest_type: :node_pending)
        )
      )
    end

    it "triages trust gates separately from policy and capacity incidents" do
      contract = trust_gate_contract_class.new(order_id: 42)

      report = contract.diagnostics.to_h

      expect(report[:routing][:facets]).to include(
        by_reason: { query_mismatch: 1 },
        by_mismatch_dimension: { trust: 1 },
        by_trust_key: { identity: 1, attestation: 1 },
        by_decision_mode: {},
        by_policy_key: {},
        by_latest_event: { node_pending: 1 },
        by_incident: { trust_gate: 1 },
        by_remediation_code: { admit_trusted_peer: 1, relax_trust_requirements: 1 },
        by_plan_action: { admit_trusted_peer: 1, relax_trust_requirements: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :admit_trusted_peer,
          scope: :routing_trust,
          automated: false,
          requires_approval: true,
          params: include(
            trust_keys: contain_exactly(:identity, :attestation),
            peer_candidates: ["orders-unknown"]
          )
        ),
        include(
          action: :relax_trust_requirements,
          scope: :routing_trust,
          automated: false,
          requires_approval: true,
          params: include(trust_keys: contain_exactly(:identity, :attestation))
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          classification: include(
            mismatch_dimensions: [:trust],
            trust_keys: contain_exactly(:identity, :attestation),
            latest_event_type: :node_pending,
            incident: :trust_gate
          ),
          remediation: contain_exactly(
            include(
              code: :admit_trusted_peer,
              details: include(
                trust_keys: contain_exactly(:identity, :attestation),
                peer_candidates: ["orders-unknown"]
              ),
              plan: include(action: :admit_trusted_peer, scope: :routing_trust, automated: false, requires_approval: true)
            ),
            include(
              code: :relax_trust_requirements,
              details: include(trust_keys: contain_exactly(:identity, :attestation)),
              plan: include(action: :relax_trust_requirements, scope: :routing_trust, automated: false, requires_approval: true)
            )
          ),
          events: include(latest_type: :node_pending)
        )
      )
    end

    it "triages governance gates separately from trust and policy incidents" do
      contract = governance_gate_contract_class.new(order_id: 42)

      report = contract.diagnostics.to_h

      expect(report[:routing][:facets]).to include(
        by_reason: { query_mismatch: 1 },
        by_mismatch_dimension: { governance: 1 },
        by_trust_key: {},
        by_governance_key: { blocked_events: 1, latest_type: 1, trust: 1 },
        by_decision_mode: {},
        by_policy_key: {},
        by_latest_event: { node_pending: 1 },
        by_incident: { governance_gate: 1 },
        by_remediation_code: { relax_governance_requirements: 1, wait_for_governance_crest: 1 },
        by_plan_action: { refresh_governance_checkpoint: 1, relax_governance_requirements: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :refresh_governance_checkpoint,
          scope: :mesh_governance,
          automated: true,
          requires_approval: false,
          params: include(
            governance_keys: contain_exactly(:blocked_events, :latest_type, :trust),
            peer_candidates: ["orders-blocked"]
          )
        ),
        include(
          action: :relax_governance_requirements,
          scope: :routing_governance,
          automated: false,
          requires_approval: true,
          params: include(governance_keys: contain_exactly(:blocked_events, :latest_type, :trust))
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          classification: include(
            mismatch_dimensions: [:governance],
            governance_keys: contain_exactly(:blocked_events, :latest_type, :trust),
            latest_event_type: :node_pending,
            incident: :governance_gate
          ),
          remediation: contain_exactly(
            include(
              code: :wait_for_governance_crest,
              details: include(
                governance_keys: contain_exactly(:blocked_events, :latest_type, :trust),
                peer_candidates: ["orders-blocked"]
              ),
              plan: include(action: :refresh_governance_checkpoint, scope: :mesh_governance, automated: true, requires_approval: false)
            ),
            include(
              code: :relax_governance_requirements,
              details: include(governance_keys: contain_exactly(:blocked_events, :latest_type, :trust)),
              plan: include(action: :relax_governance_requirements, scope: :routing_governance, automated: false, requires_approval: true)
            )
          ),
          events: include(latest_type: :node_pending)
        )
      )
    end

    it "triages capacity shortages separately from policy gates" do
      contract = capacity_contract_class.new(order_id: 42)

      report = contract.diagnostics.to_h

      expect(report[:routing][:facets]).to include(
        by_reason: { query_mismatch: 1 },
        by_mismatch_dimension: { capabilities: 1, tags: 1 },
        by_decision_mode: {},
        by_policy_key: {},
        by_latest_event: { node_pending: 1 },
        by_incident: { capacity_shortage: 1 },
        by_remediation_code: { add_capability_peer: 1, relax_tag_constraints: 1 },
        by_plan_action: { discover_capability_peers: 1, relax_route_tags: 1 }
      )
      expect(report[:routing][:plans]).to contain_exactly(
        include(
          action: :discover_capability_peers,
          scope: :mesh_capacity,
          automated: true,
          requires_approval: false,
          params: { all_of: [:gpu_inference], any_of: [] }
        ),
        include(
          action: :relax_route_tags,
          scope: :routing_query,
          automated: false,
          requires_approval: true,
          params: { tags: [:cuda] }
        )
      )
      expect(report[:routing][:entries]).to contain_exactly(
        include(
          classification: include(
            mismatch_dimensions: %i[capabilities tags],
            latest_event_type: :node_pending,
            incident: :capacity_shortage
          ),
          remediation: contain_exactly(
            include(
              code: :add_capability_peer,
              details: include(all_of: [:gpu_inference]),
              plan: include(action: :discover_capability_peers, scope: :mesh_capacity, automated: true, requires_approval: false)
            ),
            include(
              code: :relax_tag_constraints,
              details: include(tags: [:cuda]),
              plan: include(action: :relax_route_tags, scope: :routing_query, automated: false, requires_approval: true)
            )
          ),
          events: include(latest_type: :node_pending)
        )
      )
    end
  end
end
