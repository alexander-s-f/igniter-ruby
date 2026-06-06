# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"

RSpec.describe "Igniter layer loading" do
  ROOT = File.expand_path("../..", __dir__)

  def loaded_igniter_features(entrypoint)
    script = <<~RUBY
      require "json"
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require #{entrypoint.inspect}

      features = $LOADED_FEATURES.filter_map do |feature|
        next unless feature.start_with?(#{ROOT.inspect})
        next unless feature.include?("/lib/igniter") || feature.include?("/packages/")

        relative = feature.sub("#{ROOT}/", "")
        relative.start_with?("lib/") ? relative.delete_prefix("lib/") : relative
      end

      puts JSON.generate(features.sort.uniq)
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Failed to inspect #{entrypoint}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def require_failure_for(entrypoint)
    script = <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require #{entrypoint.inspect}
    RUBY

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Expected #{entrypoint} to fail to load" if status.success?

    stderr
  end

  def runtime_remote_adapter_classes_for(entrypoint)
    script = <<~RUBY
      require "json"
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require "igniter"
      before = Igniter::Runtime.remote_adapter.class.name
      require #{entrypoint.inspect}
      after = Igniter::Runtime.remote_adapter.class.name

      puts JSON.generate({ before: before, after: after })
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Failed to inspect runtime adapter for #{entrypoint}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def registered_host_names_for(entrypoint)
    script = <<~RUBY
      require "json"
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require #{entrypoint.inspect}
      names =
        if defined?(Igniter::App::HostRegistry)
          Igniter::App::HostRegistry.names.map(&:to_s).sort
        else
          []
        end
      puts JSON.generate(names)
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Failed to inspect host registry for #{entrypoint}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def registered_scheduler_names_for(entrypoint)
    script = <<~RUBY
      require "json"
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require #{entrypoint.inspect}
      puts JSON.generate(Igniter::App::SchedulerRegistry.names.map(&:to_s).sort)
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Failed to inspect scheduler registry for #{entrypoint}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def registered_loader_names_for(entrypoint)
    script = <<~RUBY
      require "json"
      $LOAD_PATH.unshift(File.expand_path("lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-sdk/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-app/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-server/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-cluster/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-rails/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-frontend/lib", #{ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-schema-rendering/lib", #{ROOT.inspect}))
      require #{entrypoint.inspect}
      puts JSON.generate(Igniter::App::LoaderRegistry.names.map(&:to_s).sort)
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    raise "Failed to inspect loader registry for #{entrypoint}: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "`require \"igniter\"` stays inside the core package through the explicit legacy lane without loading the core umbrella" do
    features = loaded_igniter_features("igniter")

    expect(features).to include("igniter.rb")
    expect(features).to include("packages/igniter-core/lib/igniter/legacy.rb")
    expect(features).to include("packages/igniter-core/lib/igniter/core/version.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core.rb")
    expect(features).not_to include("igniter/tools.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/application.rb")
    expect(features).not_to include("igniter/cluster.rb")
    expect(features).not_to include("igniter/ai.rb")
    expect(features).not_to include("igniter/channels.rb")
  end

  it "`require \"igniter/core\"` loads the contract/tool kernel without actor runtime or operational tools" do
    features = loaded_igniter_features("igniter/core")

    expect(features).to include("packages/igniter-core/lib/igniter/core.rb")
    expect(features).to include("packages/igniter-core/lib/igniter/core/tool.rb")
    expect(features).not_to include("packages/igniter-agents/lib/igniter/agent.rb")
    expect(features).not_to include("packages/igniter-agents/lib/igniter/registry.rb")
    expect(features).not_to include("packages/igniter-agents/lib/igniter/supervisor.rb")
    expect(features).not_to include("igniter/tools.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core/tool/system_discovery_tool.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core/tool/local_workflow_selector_tool.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core/tool/agent_bootstrap_tool.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/application.rb")
    expect(features).not_to include("igniter/cluster.rb")
    expect(features).not_to include("igniter/ai.rb")
  end

  it "`require \"igniter-core\"` loads the core package directly" do
    features = loaded_igniter_features("igniter-core")

    expect(features).to include("packages/igniter-core/lib/igniter-core.rb")
    expect(features).to include("packages/igniter-core/lib/igniter/legacy.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter-legacy\"` loads the explicit legacy package facade without the core umbrella" do
    features = loaded_igniter_features("igniter-legacy")

    expect(features).to include("packages/igniter-core/lib/igniter-legacy.rb")
    expect(features).to include("packages/igniter-core/lib/igniter/legacy.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/agent\"` loads the actor runtime directly from the agents package" do
    features = loaded_igniter_features("igniter/agent")

    expect(features).to include("packages/igniter-agents/lib/igniter/agent.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/registry.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/agent/mailbox.rb")
    expect(features).not_to include("packages/igniter-core/lib/igniter/core.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter-agents\"` loads the agents package directly" do
    features = loaded_igniter_features("igniter-agents")

    expect(features).to include("packages/igniter-agents/lib/igniter-agents.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/agent.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/agents.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/ai/agents.rb")
  end

  it "`require \"igniter/stack\"` loads stack support without the app runtime pack" do
    features = loaded_igniter_features("igniter/stack")

    expect(features).to include("igniter/stack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/stack_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/stack.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/application.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/runtime_pack.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/app_host_pack.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/app/runtime\"` exposes the leaf app runtime without stack support" do
    features = loaded_igniter_features("igniter/app/runtime")

    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime_pack.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/application.rb")
    expect(features).not_to include("igniter/stack.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/stack_pack.rb")
  end

  it "`require \"igniter/app\"` loads the canonical app profile umbrella" do
    features = loaded_igniter_features("igniter/app")

    expect(features).to include("packages/igniter-app/lib/igniter/app.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/stack_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/app_host_pack.rb")
    expect(features).not_to include("igniter/application.rb")
  end

  it "`require \"igniter-app\"` loads the app package directly" do
    features = loaded_igniter_features("igniter-app")

    expect(features).to include("packages/igniter-app/lib/igniter-app.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/tools\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/tools")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/tools")
  end

  it "`require \"igniter/ai\"` loads the canonical AI SDK pack directly" do
    features = loaded_igniter_features("igniter/ai")

    expect(features).to include("packages/igniter-ai/lib/igniter/ai.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/config.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/context.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/providers/base.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/transcription/transcript_result.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/executor.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/skill.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai/tool_registry.rb")
    expect(features).not_to include("packages/igniter-agents/lib/igniter/ai/agents.rb")
    expect(features).not_to include("igniter/ai.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/sdk/ai\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/sdk/ai")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/sdk/ai")
  end

  it "`require \"igniter/ai/agents\"` loads the canonical AI agents SDK pack directly" do
    features = loaded_igniter_features("igniter/ai/agents")

    expect(features).to include("packages/igniter-agents/lib/igniter/ai/agents.rb")
    expect(features).not_to include("igniter/ai/agents.rb")
  end

  it "`require \"igniter/agents\"` loads the canonical generic agents SDK pack directly" do
    features = loaded_igniter_features("igniter/agents")

    expect(features).to include("packages/igniter-agents/lib/igniter/agents.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/agents/reliability/retry_agent.rb")
    expect(features).to include("packages/igniter-agents/lib/igniter/agents/proactive_agent.rb")
    expect(features).not_to include("igniter/sdk/agents.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/sdk/agents\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/sdk/agents")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/sdk/agents")
  end

  it "`require \"igniter/sdk/ai/agents\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/sdk/ai/agents")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/sdk/ai/agents")
  end

  it "`require \"igniter/sdk/channels\"` loads the canonical channels SDK pack directly" do
    features = loaded_igniter_features("igniter/sdk/channels")

    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/channels.rb")
    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/channels/message.rb")
    expect(features).not_to include("igniter/channels.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/channels\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/channels")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/channels")
  end

  it "`require \"igniter/sdk/data\"` loads the canonical data SDK pack directly" do
    features = loaded_igniter_features("igniter/sdk/data")

    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/data.rb")
    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/data/store.rb")
    expect(features).not_to include("igniter/data.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/data\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/data")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/data")
  end

  it "`require \"igniter/sdk/tools\"` loads the canonical tools SDK pack directly" do
    features = loaded_igniter_features("igniter/sdk/tools")

    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/tools.rb")
    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk/tools/system_discovery_tool.rb")
    expect(features).not_to include("igniter/tools.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter-sdk\"` loads the sdk package directly" do
    features = loaded_igniter_features("igniter-sdk")

    expect(features).to include("packages/igniter-sdk/lib/igniter-sdk.rb")
    expect(features).to include("packages/igniter-sdk/lib/igniter/sdk.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter-ai\"` loads the ai package directly" do
    features = loaded_igniter_features("igniter-ai")

    expect(features).to include("packages/igniter-ai/lib/igniter-ai.rb")
    expect(features).to include("packages/igniter-ai/lib/igniter/ai.rb")
    expect(features).not_to include("packages/igniter-sdk/lib/igniter/sdk.rb")
    expect(features).not_to include("igniter/server.rb")
    expect(features).not_to include("igniter/app.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter/extensions\"` loads only the extension namespace entrypoint" do
    features = loaded_igniter_features("igniter/extensions")

    expect(features).to include("packages/igniter-extensions/lib/igniter/extensions.rb")
    expect(features).not_to include("packages/igniter-extensions/lib/igniter/extensions/dataflow.rb")
    expect(features).not_to include("packages/igniter-extensions/lib/igniter/extensions/saga.rb")
  end

  it "`require \"igniter-extensions\"` loads the extensions package directly" do
    features = loaded_igniter_features("igniter-extensions")

    expect(features).to include("packages/igniter-extensions/lib/igniter-extensions.rb")
    expect(features).to include("packages/igniter-extensions/lib/igniter/extensions.rb")
    expect(features).not_to include("packages/igniter-extensions/lib/igniter/extensions/dataflow.rb")
  end

  it "`require \"igniter/plugins\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/plugins")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/plugins")
  end

  it "`require \"igniter-frontend\"` loads the frontend package directly" do
    features = loaded_igniter_features("igniter-frontend")

    expect(features).to include("packages/igniter-frontend/lib/igniter-frontend.rb")
    expect(features).to include("packages/igniter-frontend/lib/igniter/frontend.rb")
    expect(features).not_to include("igniter/plugins/view.rb")
    expect(features).not_to include("igniter/view.rb")
    expect(features).not_to include("igniter/plugins/rails.rb")
  end

  it "`require \"igniter-schema-rendering\"` loads the schema rendering package directly" do
    features = loaded_igniter_features("igniter-schema-rendering")

    expect(features).to include("packages/igniter-schema-rendering/lib/igniter-schema-rendering.rb")
    expect(features).to include("packages/igniter-schema-rendering/lib/igniter/schema_rendering.rb")
    expect(features).not_to include("igniter/plugins/view.rb")
    expect(features).not_to include("igniter/plugins/rails.rb")
  end

  it "`require \"igniter/view\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/view")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/view")
  end

  it "`require \"igniter/plugins/rails\"` loads the canonical Rails plugin directly" do
    features = loaded_igniter_features("igniter/plugins/rails")

    expect(features).to include("packages/igniter-rails/lib/igniter/plugins/rails.rb")
    expect(features).to include("packages/igniter-rails/lib/igniter/plugins/rails/contract_job.rb")
    expect(features).to include("packages/igniter-rails/lib/igniter/plugins/rails/webhook_concern.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/runtime_pack.rb")
    expect(features).not_to include("packages/igniter-server/lib/igniter/server.rb")
    expect(features).not_to include("packages/igniter-cluster/lib/igniter/cluster.rb")
    expect(features).not_to include("igniter/rails.rb")
  end

  it "`require \"igniter-rails\"` loads the Rails package directly" do
    features = loaded_igniter_features("igniter-rails")

    expect(features).to include("packages/igniter-rails/lib/igniter-rails.rb")
    expect(features).to include("packages/igniter-rails/lib/igniter/plugins/rails.rb")
    expect(features).not_to include("igniter/rails.rb")
  end

  it "`require \"igniter/rails\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/rails")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/rails")
  end

  it "`require \"igniter/server\"` loads the canonical server pack directly" do
    features = loaded_igniter_features("igniter/server")

    expect(features).to include("packages/igniter-server/lib/igniter/server.rb")
    expect(features).to include("packages/igniter-server/lib/igniter/server/config.rb")
    expect(features).to include("packages/igniter-server/lib/igniter/server/router.rb")
    expect(features).to include("packages/igniter-server/lib/igniter/server/http_server.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/app_host_pack.rb")
    expect(features).not_to include("igniter/cluster.rb")
  end

  it "`require \"igniter-server\"` loads the server package directly" do
    features = loaded_igniter_features("igniter-server")

    expect(features).to include("packages/igniter-server/lib/igniter-server.rb")
    expect(features).to include("packages/igniter-server/lib/igniter/server.rb")
    expect(features).not_to include("igniter/cluster.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app.rb")
  end

  it "`require \"igniter/cluster\"` loads the canonical cluster pack directly" do
    features = loaded_igniter_features("igniter/cluster")

    expect(features).to include("packages/igniter-cluster/lib/igniter/cluster.rb")
    expect(features).to include("packages/igniter-cluster/lib/igniter/cluster/mesh.rb")
    expect(features).to include("packages/igniter-cluster/lib/igniter/cluster/remote_adapter.rb")
    expect(features).to include("packages/igniter-server/lib/igniter/server.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app.rb")
  end

  it "`require \"igniter-cluster\"` loads the cluster package directly" do
    features = loaded_igniter_features("igniter-cluster")

    expect(features).to include("packages/igniter-cluster/lib/igniter-cluster.rb")
    expect(features).to include("packages/igniter-cluster/lib/igniter/cluster.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app.rb")
  end

  it "`require \"igniter/server\"` does not mutate the runtime remote adapter by itself" do
    adapter_classes = runtime_remote_adapter_classes_for("igniter/server")

    expect(adapter_classes).to eq({
      "before" => "Igniter::Runtime::RemoteAdapter",
      "after" => "Igniter::Runtime::RemoteAdapter"
    })
  end

  it "`require \"igniter/plugins/rails\"` does not mutate the runtime remote adapter by itself" do
    adapter_classes = runtime_remote_adapter_classes_for("igniter/plugins/rails")

    expect(adapter_classes).to eq({
      "before" => "Igniter::Runtime::RemoteAdapter",
      "after" => "Igniter::Runtime::RemoteAdapter"
    })
  end

  it "`require \"igniter/plugins/rails\"` does not register app host profiles by itself" do
    host_names = registered_host_names_for("igniter/plugins/rails")

    expect(host_names).to eq([])
  end

  it "`require \"igniter/app\"` registers the app-owned host profiles" do
    host_names = registered_host_names_for("igniter/app")

    expect(host_names).to eq(["app", "cluster_app"])
  end

  it "`require \"igniter/workspace\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/workspace")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/workspace")
  end

  it "`require \"igniter/application\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/application")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/application")
  end

  it "`require \"igniter/application/runtime\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/application/runtime")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/application/runtime")
  end

  it "`require \"igniter/app\"` loads the app-owned host adapters without forcing server boot" do
    features = loaded_igniter_features("igniter/app")

    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/runtime_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/stack_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/app_host_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/app_host.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/cluster_app_host.rb")
    expect(features).not_to include("igniter/server/app_host.rb")
  end

  it "`require \"igniter/app\"` registers the default threaded scheduler pack" do
    scheduler_names = registered_scheduler_names_for("igniter/app")
    features = loaded_igniter_features("igniter/app")

    expect(scheduler_names).to eq(["threaded"])
    expect(features).to include("packages/igniter-app/lib/igniter/app/scheduler_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/threaded_scheduler_adapter.rb")
  end

  it "`require \"igniter/app\"` registers the default filesystem loader pack" do
    loader_names = registered_loader_names_for("igniter/app")
    features = loaded_igniter_features("igniter/app")

    expect(loader_names).to eq(["filesystem"])
    expect(features).to include("packages/igniter-app/lib/igniter/app/loader_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/filesystem_loader_adapter.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/scaffold_pack.rb")
    expect(features).not_to include("packages/igniter-app/lib/igniter/app/generator.rb")
  end

  it "`require \"igniter/app/scaffold_pack\"` opt-ins the scaffold generator pack" do
    features = loaded_igniter_features("igniter/app/scaffold_pack")

    expect(features).to include("packages/igniter-app/lib/igniter/app/scaffold_pack.rb")
    expect(features).to include("packages/igniter-app/lib/igniter/app/generator.rb")
  end

  it "`require \"igniter/application/scaffold_pack\"` is no longer a valid public entrypoint" do
    error = require_failure_for("igniter/application/scaffold_pack")

    expect(error).to include("cannot load such file")
    expect(error).to include("igniter/application/scaffold_pack")
  end

  it "`require \"igniter/cluster\"` does not mutate the runtime remote adapter by itself" do
    adapter_classes = runtime_remote_adapter_classes_for("igniter/cluster")

    expect(adapter_classes).to eq({
      "before" => "Igniter::Runtime::RemoteAdapter",
      "after" => "Igniter::Runtime::RemoteAdapter"
    })
  end

  it "`require \"igniter/cluster\"` does not register app host profiles by itself" do
    host_names = registered_host_names_for("igniter/cluster")

    expect(host_names).to eq([])
  end
end
