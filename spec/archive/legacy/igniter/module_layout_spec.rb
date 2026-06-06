# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter module layout" do
  MODULE_LAYOUT_ROOT = File.expand_path("../..", __dir__)
  IGNITER_LIB = File.join(MODULE_LAYOUT_ROOT, "lib/igniter")
  CORE_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-core/lib/igniter")
  AGENTS_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-agents/lib/igniter")
  AI_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-ai/lib/igniter")
  SDK_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-sdk/lib/igniter")
  EXTENSIONS_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-extensions/lib/igniter")
  APP_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-app/lib/igniter")
  SERVER_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-server/lib/igniter")
  CLUSTER_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-cluster/lib/igniter")
  RAILS_LIB = File.join(MODULE_LAYOUT_ROOT, "packages/igniter-rails/lib/igniter")

  def children_for(path)
    Dir.children(path).sort
  end

  it "keeps only canonical top-level runtime and registry entrypoints under lib/igniter" do
    expect(children_for(IGNITER_LIB)).to eq(%w[
      monorepo_packages.rb
      stack.rb
    ])
  end

  it "keeps app entrypoints inside the local app package" do
    expect(children_for(APP_LIB)).to eq(%w[
      app
      app.rb
      ignite
      ignite.rb
    ])
  end

  it "keeps ignite value objects under the canonical ignite namespace inside the app package" do
    expect(children_for(File.join(APP_LIB, "ignite"))).to eq(%w[
      bootstrap_agent.rb
      bootstrap_target.rb
      deployment_intent.rb
      ignition_agent.rb
      ignition_plan.rb
      ignition_report.rb
      store.rb
      stores
      trail.rb
    ])
  end

  it "keeps app packs under the canonical app namespace inside the package" do
    expect(children_for(File.join(APP_LIB, "app"))).to include(
      "app_config.rb",
      "app_host.rb",
      "app_host_pack.rb",
      "credentials",
      "credentials.rb",
      "diagnostics.rb",
      "evolution.rb",
      "generator.rb",
      "generators",
      "observability",
      "observability.rb",
      "operator",
      "operator.rb",
      "observability_pack.rb",
      "runtime.rb",
      "runtime_pack.rb",
      "scaffold_pack.rb",
      "stack.rb",
      "stack_pack.rb"
    )
  end

  it "keeps observability handlers under the canonical app observability namespace" do
    expect(children_for(File.join(APP_LIB, "app", "observability"))).to eq(%w[
      operator_action_handler.rb
      operator_console_handler.rb
      operator_overview_handler.rb
    ])
  end

  it "keeps shared operator vocabulary under the canonical app operator namespace" do
    expect(children_for(File.join(APP_LIB, "app", "operator"))).to eq(%w[
      dispatcher.rb
      handler_registry.rb
      handler_result.rb
      handlers
      handlers.rb
      lifecycle_contract.rb
      policy.rb
    ])

    expect(children_for(File.join(APP_LIB, "app", "operator", "handlers"))).to eq(%w[
      base.rb
      ignite_handler.rb
      orchestration_handler.rb
    ])
  end

  it "keeps orchestration runtime builders and queries under the canonical app orchestration namespace" do
    expect(children_for(File.join(APP_LIB, "app", "orchestration"))).to include(
      "action_result_builder.rb",
      "runtime_event_query.rb",
      "runtime_query_overview_builder.rb",
      "runtime_overview_builder.rb",
      "runtime_result_builder.rb"
    )
  end

  it "keeps credential foundations under the canonical app credentials namespace" do
    expect(children_for(File.join(APP_LIB, "app", "credentials"))).to eq(%w[
      config_loader.rb
      credential.rb
      credential_policy.rb
      events
      events.rb
      lease_request.rb
      policies
      policies.rb
      store.rb
      stores
      trail.rb
    ])

    expect(children_for(File.join(APP_LIB, "app", "credentials", "events"))).to eq(%w[
      credential_event.rb
    ])

    expect(children_for(File.join(APP_LIB, "app", "credentials", "policies"))).to eq(%w[
      ephemeral_lease_policy.rb
      local_only_policy.rb
    ])

    expect(children_for(File.join(APP_LIB, "app", "credentials", "stores"))).to eq(%w[
      file_store.rb
    ])
  end

  it "keeps server entrypoints inside the local server package" do
    expect(children_for(SERVER_LIB)).to eq(%w[
      server
      server.rb
    ])
  end

  it "keeps server packs under the canonical server namespace inside the package" do
    expect(children_for(File.join(SERVER_LIB, "server"))).to include(
      "agent_session_store.rb",
      "agent_transport.rb",
      "app_host.rb",
      "client.rb",
      "config.rb",
      "handlers",
      "http_server.rb",
      "rack_app.rb",
      "registry.rb",
      "remote_adapter.rb",
      "router.rb",
      "server_logger.rb"
    )
  end

  it "keeps cluster entrypoints inside the local cluster package" do
    expect(children_for(CLUSTER_LIB)).to eq(%w[
      cluster
      cluster.rb
    ])
  end

  it "keeps cluster packs under the canonical cluster namespace inside the package" do
    expect(children_for(File.join(CLUSTER_LIB, "cluster"))).to include(
      "consensus",
      "consensus.rb",
      "diagnostics",
      "diagnostics.rb",
      "events",
      "events.rb",
      "governance",
      "governance.rb",
      "identity",
      "identity.rb",
      "mesh",
      "mesh.rb",
      "agent_route_resolver.rb",
      "ownership",
      "ownership.rb",
      "projection_store.rb",
      "rag",
      "rag.rb",
      "remote_adapter.rb",
      "routed_agent_adapter.rb",
      "replication",
      "replication.rb",
      "routing_plan_executor.rb",
      "routing_plan_result.rb",
      "trust",
      "trust.rb"
    )
  end

  it "keeps core entrypoints inside the local core package" do
    expect(children_for(CORE_LIB)).to eq(%w[
      core
      core.rb
    ])
  end

  it "keeps core packs under the canonical core namespace inside the package" do
    expect(children_for(File.join(CORE_LIB, "core"))).to include(
      "compiler",
      "compiler.rb",
      "contract.rb",
      "diagnostics.rb",
      "dto",
      "dto.rb",
      "dsl.rb",
      "errors.rb",
      "events.rb",
      "executor.rb",
      "extensions.rb",
      "model.rb",
      "runtime.rb",
      "tool.rb",
      "type_system.rb",
      "version.rb"
    )
  end

  it "keeps actor runtime entrypoints inside the local agents package" do
    expect(children_for(AGENTS_LIB)).to eq(%w[
      agent
      agent.rb
      agents
      agents.rb
      ai
      registry.rb
      runtime
      supervisor.rb
    ])
  end

  it "keeps actor runtime packs under the canonical agents namespaces inside the package" do
    expect(children_for(File.join(AGENTS_LIB, "agent"))).to eq(%w[
      mailbox.rb
      message.rb
      ref.rb
      runner.rb
      state_holder.rb
    ])

    expect(children_for(File.join(AGENTS_LIB, "agents"))).to include(
      "observability",
      "pipeline",
      "proactive",
      "proactive_agent.rb",
      "reliability",
      "scheduling"
    )

    expect(children_for(File.join(AGENTS_LIB, "ai"))).to eq(%w[
      agents
      agents.rb
    ])

    expect(children_for(File.join(AGENTS_LIB, "runtime"))).to eq(%w[
      registry_agent_adapter.rb
    ])
  end

  it "keeps sdk entrypoints inside the local sdk package" do
    expect(children_for(SDK_LIB)).to eq(%w[
      sdk
      sdk.rb
    ])
  end

  it "keeps AI SDK pack entrypoints inside the local ai package" do
    expect(children_for(AI_LIB)).to eq(%w[
      ai
      ai.rb
    ])
  end

  it "keeps AI packs under the canonical ai namespace inside the package" do
    expect(children_for(File.join(AI_LIB, "ai"))).to include(
      "config.rb",
      "context.rb",
      "executor.rb",
      "providers",
      "skill",
      "skill.rb",
      "tool_registry.rb",
      "transcription"
    )
  end

  it "keeps skill runtime helpers under the canonical ai skill namespace" do
    expect(children_for(File.join(AI_LIB, "ai", "skill"))).to eq(%w[
      feedback.rb
      output_schema.rb
      runtime_contract.rb
    ])
  end

  it "does not keep sdk/ai entrypoints inside the sdk package" do
    expect(children_for(File.join(SDK_LIB, "sdk"))).not_to include(
      "ai",
      "ai.rb"
    )
  end

  it "keeps sdk packs under the canonical sdk namespace inside the package" do
    expect(children_for(File.join(SDK_LIB, "sdk"))).to eq(%w[
      channels
      channels.rb
      data
      data.rb
      tools
      tools.rb
    ])
  end

  it "keeps extension entrypoints inside the local extensions package" do
    expect(children_for(EXTENSIONS_LIB)).to eq(%w[
      extensions
      extensions.rb
    ])
  end

  it "keeps public extension entrypoints under the canonical extensions namespace inside the package" do
    expect(children_for(File.join(EXTENSIONS_LIB, "extensions"))).to eq(%w[
      auditing.rb
      capabilities.rb
      content_addressing.rb
      dataflow.rb
      differential.rb
      execution_report.rb
      incremental.rb
      introspection.rb
      invariants.rb
      provenance.rb
      reactive.rb
      saga.rb
    ])
  end

  it "keeps rails plugin entrypoints inside the local rails package" do
    expect(children_for(File.join(RAILS_LIB, "plugins"))).to eq(%w[
      rails
      rails.rb
    ])
  end
end
