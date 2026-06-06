# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "ostruct"
require "igniter/stack"
require "igniter/app"
require "igniter/cluster"

RSpec.describe Igniter::Stack do
  around do |example|
    original_load_path = $LOAD_PATH.dup
    original_env = ENV["IGNITER_ENV"]
    original_port = ENV["PORT"]
    original_ignite_target = ENV["IGNITER_IGNITE_TARGET"]
    original_ignite_intent = ENV["IGNITER_IGNITE_INTENT"]
    original_ignite_mode = ENV["IGNITER_IGNITE_MODE"]

    example.run
  ensure
    $LOAD_PATH.replace(original_load_path)
    ENV["IGNITER_ENV"] = original_env
    ENV["PORT"] = original_port
    ENV["IGNITER_IGNITE_TARGET"] = original_ignite_target
    ENV["IGNITER_IGNITE_INTENT"] = original_ignite_intent
    ENV["IGNITER_IGNITE_MODE"] = original_ignite_mode
    Igniter::Cluster::Mesh.reset!
  end

  def build_workspace(root:, environment: nil, app_classes: nil)
    app_classes ||= {
      main: Class.new(Igniter::App),
      dashboard: Class.new(Igniter::App)
    }

    Class.new(described_class).tap do |workspace|
      workspace.root_dir(root)
      workspace.environment(environment) if environment
      workspace.app :main, path: "apps/main", klass: app_classes.fetch(:main), default: true
      workspace.app :dashboard, path: "apps/dashboard", klass: app_classes.fetch(:dashboard)
    end
  end

  it "loads root app and node defaults from stack.yml" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: dashboard
          default_node: edge
          shared_lib_paths:
            - lib/shared
        nodes:
          edge:
            port: 4668
      YAML

      workspace = build_workspace(root: tmp)

      expect(workspace.root_app).to eq(:dashboard)
      expect(workspace.default_node).to eq(:edge)
      expect(workspace.node_profile(:edge).fetch("port")).to eq(4668)
      expect(workspace.stack_settings.dig("stack", "shared_lib_paths")).to eq(["lib/shared"])
    end
  end

  it "merges environment overlays into stack settings" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config", "environments"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
        nodes:
          main:
            port: 4567
      YAML
      File.write(File.join(tmp, "config", "environments", "production.yml"), <<~YAML)
        stack:
          root_app: dashboard
        nodes:
          main:
            port: 5567
          edge:
            port: 5568
      YAML

      workspace = build_workspace(root: tmp, environment: "production")

      expect(workspace.root_app).to eq(:dashboard)
      expect(workspace.node_profile(:main).fetch("port")).to eq(5567)
      expect(workspace.node_profile(:edge).fetch("port")).to eq(5568)
    end
  end

  it "normalizes ignite config into an ignition plan with local and remote targets" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config", "environments"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
      YAML
      File.write(File.join(tmp, "config", "environments", "production.yml"), <<~YAML)
        ignite:
          mode: expand
          strategy: parallel
          approval: required
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
                - whisper_asr
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
                - local_llm
              bootstrap:
                ruby: "3.2"
      YAML

      workspace = build_workspace(root: tmp, environment: "production")
      plan = workspace.ignition_plan

      expect(plan).to be_a(Igniter::Ignite::IgnitionPlan)
      expect(plan.ignite_mode).to eq(:expand)
      expect(plan.strategy).to eq(:parallel)
      expect(plan.approval_mode).to eq(:required)
      expect(plan.local_replica_intents.size).to eq(1)
      expect(plan.remote_intents.size).to eq(1)

      local_target = plan.local_replica_intents.first.target
      remote_target = plan.remote_intents.first.target

      expect(local_target).to be_local_replica
      expect(local_target.server_settings).to include("host" => "0.0.0.0", "port" => 4568)
      expect(local_target.capability_intent).to eq(%i[audio_ingest whisper_asr])

      expect(remote_target).to be_ssh_server
      expect(remote_target.locator).to include("config_path" => "config/ssh_hp.yml")
      expect(remote_target.capability_intent).to eq(%i[call_analysis local_llm])

      expect(workspace.deployment_snapshot.dig("ignite", "summary")).to include(
        "total_intents" => 2,
        "local_replicas" => 1,
        "remote_targets" => 1
      )
    end
  end

  it "returns an ignition report that awaits approval by default when approval is required" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: required
          replicas:
            - name: edge-1
              port: 4568
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite

      expect(report).to be_a(Igniter::Ignite::IgnitionReport)
      expect(report).to be_awaiting_approval
      expect(report.by_status).to include(awaiting_approval: 1)
      expect(report.entries.first).to include(
        target_id: "edge-1",
        status: :awaiting_approval,
        action: :approve_ignition
      )
    end
  end

  it "prepares local replica launch entries once ignition is approved" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: required
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(approved: true)
      entry = report.entries.first

      expect(report).to be_prepared
      expect(report.by_status).to include(prepared: 1)
      expect(entry).to include(
        target_id: "edge-1",
        kind: :local_replica,
        status: :prepared,
        action: :start_local_runtime_unit,
        host: "0.0.0.0",
        port: 4568,
        capabilities: [:audio_ingest]
      )
      expect(entry.fetch(:environment)).to include(
        IGNITER_IGNITE_REPLICA: "true",
        IGNITER_IGNITE_TARGET: "edge-1"
      )
      expect(entry.fetch(:admission)).to include(required: true, status: :pending_bootstrap)
      expect(entry.fetch(:join)).to include(required: true, status: :pending_bootstrap)
      expect(report.summary).to include(
        admission_required: 1,
        join_required: 1,
        by_admission_status: { pending_bootstrap: 1 },
        by_join_status: { pending_bootstrap: 1 }
      )
    end
  end

  it "persists ignition history and can reload the durable trail" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite
      history = workspace.ignition_history(limit: 10)
      log_path = File.join(tmp, "var", "ignite", "spark_crm.ndjson")

      expect(report).to be_prepared
      expect(history).to include(
        total: be >= 1,
        latest_type: :ignition_report_snapshot,
        persistence: include(enabled: true, path: log_path)
      )
      expect(history[:by_type]).to include(
        ignition_started: 1,
        intent_prepared: 1,
        ignition_finished: 1,
        ignition_report_snapshot: 1
      )
      expect(File).to exist(log_path)

      workspace.reload_ignition_trail!
      reloaded = workspace.ignition_history(limit: 10)

      expect(reloaded).to include(
        total: history[:total],
        latest_type: :ignition_report_snapshot,
        persistence: include(enabled: true, path: log_path)
      )
      expect(reloaded[:by_type]).to eq(history[:by_type])
    end
  end

  it "persists credential history and can reload the durable trail" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
      YAML

      workspace = build_workspace(root: tmp)
      log_path = File.join(tmp, "var", "credentials", "spark_crm.ndjson")

      workspace.record_credential_event(
        event: :lease_requested,
        credential_key: :openai_api,
        policy_name: :ephemeral_lease,
        node: "main",
        target_node: "replica-1",
        source: :credential_runtime
      )
      workspace.record_credential_event(
        event: :lease_denied,
        credential_key: :openai_api,
        policy_name: :local_only,
        node: "main",
        target_node: "office-edge",
        source: :credential_policy,
        reason: :weak_trust_denied
      )

      history = workspace.credential_history(limit: 10)

      expect(history).to include(
        total: 2,
        latest_type: :lease_denied,
        latest_status: :denied,
        persistence: include(enabled: true, path: log_path)
      )
      expect(history[:by_event]).to include(lease_requested: 1, lease_denied: 1)
      expect(File).to exist(log_path)

      workspace.reload_credential_trail!
      reloaded = workspace.credential_history(limit: 10)

      expect(reloaded).to include(
        total: 2,
        latest_type: :lease_denied,
        latest_status: :denied,
        persistence: include(enabled: true, path: log_path)
      )
      expect(reloaded[:by_event]).to eq(history[:by_event])
      expect(reloaded[:by_policy]).to eq(history[:by_policy])
    end
  end

  it "supports a canonical credential lease request flow on top of the audit trail" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
      YAML

      workspace = build_workspace(root: tmp)
      credential = Igniter::App::Credentials::Credential.new(
        key: :openai_api,
        label: "OpenAI API",
        provider: :openai,
        scope: :local,
        node: "main",
        policy: Igniter::App::Credentials::Policies::EphemeralLeasePolicy.new
      )

      requested = workspace.request_credential_lease(
        credential: credential,
        target_node: "replica-1",
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_runtime,
        metadata: { ttl_seconds: 300 }
      )
      issued = workspace.issue_credential_lease(
        requested.fetch(:request),
        lease_id: "lease-123",
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_runtime
      )
      revoked = workspace.revoke_credential_lease(
        issued.fetch(:request),
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_runtime,
        reason: :completed
      )

      expect(requested).to include(
        policy_allowed: true,
        next_operation: :issue_or_deny,
        event: include(
          event: :lease_requested,
          credential_key: :openai_api,
          policy_name: :ephemeral_lease,
          target_node: "replica-1"
        )
      )
      expect(issued).to include(
        policy_allowed: true,
        event: include(
          event: :lease_issued,
          lease_id: "lease-123",
          status: :issued
        )
      )
      expect(revoked).to include(
        event: include(
          event: :lease_revoked,
          lease_id: "lease-123",
          reason: :completed,
          status: :revoked
        )
      )

      history = workspace.credential_history(limit: 10, order_by: :timestamp, direction: :asc)

      expect(history).to include(
        total: 3,
        latest_type: :lease_revoked,
        latest_status: :revoked
      )
      expect(history[:by_event]).to include(
        lease_requested: 1,
        lease_issued: 1,
        lease_revoked: 1
      )
    end
  end

  it "surfaces denied credential lease requests when policy does not allow remote scope" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
      YAML

      workspace = build_workspace(root: tmp)
      credential = Igniter::App::Credentials::Credential.new(
        key: :anthropic_api,
        label: "Anthropic API",
        provider: :anthropic,
        scope: :local,
        node: "main",
        policy: Igniter::App::Credentials::Policies::LocalOnlyPolicy.new
      )

      requested = workspace.request_credential_lease(
        credential: credential,
        target_node: "office-edge",
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_policy
      )
      denied = workspace.deny_credential_lease(
        requested.fetch(:request),
        reason: :policy_denied,
        actor: "ops:alex",
        origin: "operator_console",
        source: :credential_policy
      )

      expect(requested).to include(
        policy_allowed: false,
        next_operation: :deny
      )
      expect(denied).to include(
        policy_allowed: false,
        event: include(
          event: :lease_denied,
          credential_key: :anthropic_api,
          policy_name: :local_only,
          reason: :policy_denied,
          status: :denied
        )
      )
    end
  end

  it "marks remote targets as deferred after approval until remote bootstrap exists" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite
      entry = report.entries.first

      expect(report).to be_pending_remote
      expect(report.by_status).to include(deferred: 1)
      expect(entry).to include(
        target_id: "hp-call-analysis",
        kind: :ssh_server,
        status: :deferred,
        action: :await_remote_bootstrap,
        capabilities: [:call_analysis]
      )
      expect(entry.fetch(:locator)).to include(config_path: "config/ssh_hp.yml")
      expect(entry.fetch(:admission)).to include(required: true, status: :pending_bootstrap)
      expect(entry.fetch(:join)).to include(required: true, status: :pending_bootstrap)
    end
  end

  it "can bootstrap remote ssh targets through the ignition bootstrap agent" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
        strategy: tarball
        target_path: /srv/igniter/spark-crm
      YAML

      fake_session_class = Class.new do
        attr_reader :host, :user, :key, :port

        def initialize(host:, user:, key:, port:)
          @host = host
          @user = user
          @key = key
          @port = port
        end

        def test_connection
          true
        end
      end

      fake_bootstrapper = Class.new do
        attr_reader :events

        def initialize
          @events = []
        end

        def install(session:, manifest:, env:, target_path:)
          @events << [:install, session.host, manifest.instance_id.class.name, env["IGNITER_IGNITE_TARGET"], target_path]
        end

        def start(session:, manifest:, target_path:)
          @events << [:start, session.host, manifest.startup_command.class.name, target_path]
        end

        def verify(session:, target_path:)
          @events << [:verify, session.host, target_path]
          true
        end
      end.new

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { fake_session_class.new(host: host, user: user, key: key, port: port) },
        bootstrapper_factory: ->(strategy, **_options) do
          expect(strategy).to eq(:tarball)
          fake_bootstrapper
        end
      )
      entry = report.entries.first

      expect(report.status).to eq(:awaiting_join)
      expect(entry).to include(
        target_id: "hp-call-analysis",
        kind: :ssh_server,
        status: :bootstrapped,
        action: :await_remote_join,
        host: "10.0.0.50",
        port: 22
      )
      expect(entry.fetch(:bootstrap)).to include(
        strategy: :tarball,
        target_path: "/srv/igniter/spark-crm",
        host: "10.0.0.50",
        user: "deploy",
        port: 22,
        verified: true
      )
      expect(entry.fetch(:admission)).to include(required: true, status: :pending_bootstrap)
      expect(entry.fetch(:join)).to include(required: true, status: :awaiting_join)
      expect(fake_bootstrapper.events.map(&:first)).to eq(%i[install start verify])
    end
  end

  it "can route remote ignition through the real mesh admission workflow" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true
      )
      entry = report.entries.first

      expect(report.status).to eq(:awaiting_admission)
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :awaiting_admission_approval,
        action: :approve_cluster_admission
      )
      expect(entry.fetch(:admission)).to include(
        required: true,
        status: :awaiting_approval,
        outcome: :pending_approval
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :blocked_by_admission,
        node_id: "hp-call-analysis",
        peer_name: "hp-call-analysis"
      )
      expect(Igniter::Cluster::Mesh.pending_admissions.size).to eq(1)
    end
  end

  it "can auto-approve remote admission before bootstrap and await join" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true,
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) do
          Class.new do
            def initialize(host:, user:, key:, port:) = nil

            def test_connection
              true
            end
          end.new(host: host, user: user, key: key, port: port)
        end,
        bootstrapper_factory: ->(_strategy, **_options) do
          Class.new do
            def install(session:, manifest:, env:, target_path:) = nil

            def start(session:, manifest:, target_path:) = nil

            def verify(session:, target_path:)
              true
            end
          end.new
        end
      )
      entry = report.entries.first

      expect(report.status).to eq(:awaiting_join)
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :bootstrapped,
        action: :await_remote_join
      )
      expect(entry.fetch(:admission)).to include(required: true, status: :admitted, outcome: :admitted)
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :awaiting_join,
        node_id: "hp-call-analysis",
        peer_name: "hp-call-analysis"
      )
      expect(Igniter::Cluster::Mesh.pending_admissions).to be_empty
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("hp-call-analysis")).to be(true)
    end
  end

  it "blocks remote ignition targets when bootstrap fails" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      failing_session_class = Class.new do
        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          false
        end
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { failing_session_class.new(host: host, user: user, key: key, port: port) }
      )
      entry = report.entries.first

      expect(report.status).to eq(:blocked)
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :blocked,
        action: :remote_bootstrap_failed
      )
      expect(entry.fetch(:bootstrap_error)).to include("SSH connectivity test failed")
      expect(entry.fetch(:admission)).to include(required: true, status: :blocked)
      expect(entry.fetch(:join)).to include(required: true, status: :blocked)
    end
  end

  it "can confirm join for bootstrapped remote ssh targets" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) do
          Class.new do
            def initialize(host:, user:, key:, port:) = nil

            def test_connection
              true
            end
          end.new(host: host, user: user, key: key, port: port)
        end,
        bootstrapper_factory: ->(_strategy, **_options) do
          Class.new do
            def install(session:, manifest:, env:, target_path:) = nil

            def start(session:, manifest:, target_path:) = nil

            def verify(session:, target_path:)
              true
            end
          end.new
        end
      )
      joined = workspace.confirm_ignite_join(
        report: report,
        target_id: "hp-call-analysis",
        url: "http://10.0.0.50:4567"
      )
      entry = joined.entries.first

      expect(joined).to be_joined
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :joined,
        action: :runtime_joined,
        url: "http://10.0.0.50:4567"
      )
      expect(entry.fetch(:admission)).to include(
        required: false,
        status: :implicit_remote
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :joined,
        url: "http://10.0.0.50:4567"
      )
    end
  end

  it "can reconcile bootstrapped remote ignition targets from mesh peer discovery" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) do
          Class.new do
            def initialize(host:, user:, key:, port:) = nil

            def test_connection
              true
            end
          end.new(host: host, user: user, key: key, port: port)
        end,
        bootstrapper_factory: ->(_strategy, **_options) do
          Class.new do
            def install(session:, manifest:, env:, target_path:) = nil

            def start(session:, manifest:, target_path:) = nil

            def verify(session:, target_path:)
              true
            end
          end.new
        end
      )

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
      end
      Igniter::Cluster::Mesh.config.peer_registry.register(
        Igniter::Cluster::Mesh::Peer.new(
          name: "hp-call-analysis",
          url: "http://10.0.0.50:4567",
          capabilities: [:call_analysis],
          tags: [],
          metadata: {
            mesh_trust: { status: "trusted", trusted: true }
          }
        )
      )

      reconciled = workspace.reconcile_ignite(report: report, mesh: Igniter::Cluster::Mesh)
      entry = reconciled.entries.first

      expect(reconciled).to be_joined
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :joined,
        action: :runtime_joined,
        url: "http://10.0.0.50:4567"
      )
      expect(entry.fetch(:admission)).to include(status: :admitted)
      expect(entry.fetch(:join)).to include(status: :joined, url: "http://10.0.0.50:4567")
      expect(entry.fetch(:reconciled_from_mesh)).to include(peer_name: "hp-call-analysis")
    end
  end

  it "can automatically await mesh join for bootstrapped remote targets" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
      end

      join_thread = Thread.new do
        sleep 0.05
        Igniter::Cluster::Mesh.config.peer_registry.register(
          Igniter::Cluster::Mesh::Peer.new(
            name: "hp-call-analysis",
            url: "http://10.0.0.50:4567",
            capabilities: [:call_analysis],
            tags: [],
            metadata: {
              mesh_trust: { status: "trusted", trusted: true }
            }
          )
        )
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        bootstrap_remote: true,
        await_join: true,
        join_timeout: 1,
        join_poll_interval: 0.01,
        session_factory: ->(host:, user:, key:, port:) do
          Class.new do
            def initialize(host:, user:, key:, port:) = nil

            def test_connection
              true
            end
          end.new(host: host, user: user, key: key, port: port)
        end,
        bootstrapper_factory: ->(_strategy, **_options) do
          Class.new do
            def install(session:, manifest:, env:, target_path:) = nil

            def start(session:, manifest:, target_path:) = nil

            def verify(session:, target_path:)
              true
            end
          end.new
        end
      )
      entry = report.entries.first

      expect(report).to be_joined
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :joined,
        action: :runtime_joined,
        url: "http://10.0.0.50:4567"
      )
    ensure
      join_thread&.join
    end
  end

  it "can detach a joined remote ignition target through ssh decommission without dropping trust" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
        target_path: /srv/igniter/spark-crm
        drain_command: systemctl stop spark-crm-drain
      YAML

      fake_session_class = Class.new do
        class << self
          attr_reader :commands, :verifications

          def reset!
            @commands = []
            @verifications = []
          end
        end

        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end

        def exec!(command)
          self.class.commands << command
          true
        end

        def exec(command)
          self.class.verifications << command
          { success: true, stdout: "", stderr: "", exit_code: 0 }
        end
      end
      fake_session_class.reset!

      noop_bootstrapper = Class.new do
        def install(session:, manifest:, env:, target_path:) = nil

        def start(session:, manifest:, target_path:) = nil

        def verify(session:, target_path:)
          true
        end
      end.new

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      admitted = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true,
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { fake_session_class.new(host: host, user: user, key: key, port: port) },
        bootstrapper_factory: ->(_strategy, **_options) { noop_bootstrapper }
      )
      joined = workspace.confirm_ignite_join(
        report: admitted,
        target_id: "hp-call-analysis",
        url: "http://10.0.0.50:4567",
        mesh: Igniter::Cluster::Mesh
      )

      detached = workspace.detach_ignite_target(
        report: joined,
        target_id: "hp-call-analysis",
        mesh: Igniter::Cluster::Mesh,
        metadata: { reason: "operator detach" },
        session_factory: ->(host:, user:, key:, port:) { fake_session_class.new(host: host, user: user, key: key, port: port) }
      )
      entry = detached.entries.first

      expect(detached).to be_detached
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :detached,
        action: :remote_detached
      )
      expect(entry.fetch(:join)).to include(required: false, status: :detached)
      expect(entry.fetch(:detach)).to include(reason: "operator detach")
      expect(entry.dig(:detach, :transport)).to include(
        host: "10.0.0.50",
        port: 22,
        target_path: "/srv/igniter/spark-crm",
        drain_command: "systemctl stop spark-crm-drain",
        verified_shutdown: true
      )
      expect(entry.dig(:detach, :acknowledged)).to be(true)
      expect(fake_session_class.commands.first).to eq("systemctl stop spark-crm-drain")
      expect(fake_session_class.commands.last).to include("igniter.pid")
      expect(fake_session_class.commands.last).not_to include("rm -rf")
      expect(fake_session_class.verifications.last).to include("pgrep -f /srv/igniter/spark-crm")
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("hp-call-analysis")).to be_nil
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("hp-call-analysis")).to be(true)
    end
  end

  it "keeps a joined remote ignition target active when ssh detach transport fails" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
        target_path: /srv/igniter/spark-crm
      YAML

      bootstrap_session_class = Class.new do
        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end
      end

      failing_session_class = Class.new do
        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end

        def exec!(_command)
          raise Igniter::Cluster::Replication::SSHSession::SSHError, "remote stop failed"
        end
      end

      noop_bootstrapper = Class.new do
        def install(session:, manifest:, env:, target_path:) = nil

        def start(session:, manifest:, target_path:) = nil

        def verify(session:, target_path:)
          true
        end
      end.new

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      admitted = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true,
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { bootstrap_session_class.new(host: host, user: user, key: key, port: port) },
        bootstrapper_factory: ->(_strategy, **_options) { noop_bootstrapper }
      )
      joined = workspace.confirm_ignite_join(
        report: admitted,
        target_id: "hp-call-analysis",
        url: "http://10.0.0.50:4567",
        mesh: Igniter::Cluster::Mesh
      )

      blocked = workspace.detach_ignite_target(
        report: joined,
        target_id: "hp-call-analysis",
        mesh: Igniter::Cluster::Mesh,
        metadata: { reason: "operator detach" },
        session_factory: ->(host:, user:, key:, port:) { failing_session_class.new(host: host, user: user, key: key, port: port) }
      )
      entry = blocked.entries.first

      expect(blocked).to be_blocked
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :blocked,
        action: :remote_detach_failed
      )
      expect(entry.fetch(:decommission_error)).to include("remote stop failed")
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("hp-call-analysis")).not_to be_nil
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("hp-call-analysis")).to be(true)
    end
  end

  it "keeps a joined remote ignition target active when shutdown verification never acknowledges detach" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
        target_path: /srv/igniter/spark-crm
        shutdown_timeout: 0
      YAML

      bootstrap_session_class = Class.new do
        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end
      end

      unverified_session_class = Class.new do
        class << self
          attr_reader :commands, :verifications

          def reset!
            @commands = []
            @verifications = []
          end
        end

        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end

        def exec!(command)
          self.class.commands << command
          true
        end

        def exec(command)
          self.class.verifications << command
          { success: false, stdout: "", stderr: "still running", exit_code: 1 }
        end
      end
      unverified_session_class.reset!

      noop_bootstrapper = Class.new do
        def install(session:, manifest:, env:, target_path:) = nil

        def start(session:, manifest:, target_path:) = nil

        def verify(session:, target_path:)
          true
        end
      end.new

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      admitted = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true,
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { bootstrap_session_class.new(host: host, user: user, key: key, port: port) },
        bootstrapper_factory: ->(_strategy, **_options) { noop_bootstrapper }
      )
      joined = workspace.confirm_ignite_join(
        report: admitted,
        target_id: "hp-call-analysis",
        url: "http://10.0.0.50:4567",
        mesh: Igniter::Cluster::Mesh
      )

      blocked = workspace.detach_ignite_target(
        report: joined,
        target_id: "hp-call-analysis",
        mesh: Igniter::Cluster::Mesh,
        metadata: { reason: "operator detach" },
        session_factory: ->(host:, user:, key:, port:) { unverified_session_class.new(host: host, user: user, key: key, port: port) }
      )
      entry = blocked.entries.first

      expect(blocked).to be_blocked
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :blocked,
        action: :remote_detach_failed
      )
      expect(entry.fetch(:decommission_error)).to include("remote shutdown verification failed")
      expect(entry.fetch(:detach)).to include(reason: "operator detach", acknowledged: false)
      expect(unverified_session_class.commands.last).to include("igniter.pid")
      expect(unverified_session_class.verifications.last).to include("pgrep -f /srv/igniter/spark-crm")
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("hp-call-analysis")).not_to be_nil
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("hp-call-analysis")).to be(true)
    end
  end

  it "can tear down a joined remote ignition target and remove cluster trust" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          servers:
            - target: config/ssh_hp.yml
              name: hp-call-analysis
              capabilities:
                - call_analysis
      YAML
      File.write(File.join(tmp, "config", "ssh_hp.yml"), <<~YAML)
        host: 10.0.0.50
        user: deploy
        target_path: /srv/igniter/spark-crm
      YAML

      fake_session_class = Class.new do
        class << self
          attr_reader :commands, :verifications

          def reset!
            @commands = []
            @verifications = []
          end
        end

        def initialize(host:, user:, key:, port:) = nil

        def test_connection
          true
        end

        def exec!(command)
          self.class.commands << command
          true
        end

        def exec(command)
          self.class.verifications << command
          { success: true, stdout: "", stderr: "", exit_code: 0 }
        end
      end
      fake_session_class.reset!

      noop_bootstrapper = Class.new do
        def install(session:, manifest:, env:, target_path:) = nil

        def start(session:, manifest:, target_path:) = nil

        def verify(session:, target_path:)
          true
        end
      end.new

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      admitted = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true,
        bootstrap_remote: true,
        session_factory: ->(host:, user:, key:, port:) { fake_session_class.new(host: host, user: user, key: key, port: port) },
        bootstrapper_factory: ->(_strategy, **_options) { noop_bootstrapper }
      )
      joined = workspace.confirm_ignite_join(
        report: admitted,
        target_id: "hp-call-analysis",
        url: "http://10.0.0.50:4567",
        mesh: Igniter::Cluster::Mesh
      )

      torn_down = workspace.teardown_ignite_target(
        report: joined,
        target_id: "hp-call-analysis",
        mesh: Igniter::Cluster::Mesh,
        metadata: { reason: "retire host" },
        session_factory: ->(host:, user:, key:, port:) { fake_session_class.new(host: host, user: user, key: key, port: port) }
      )
      entry = torn_down.entries.first

      expect(torn_down).to be_torn_down
      expect(entry).to include(
        target_id: "hp-call-analysis",
        status: :torn_down,
        action: :remote_torn_down
      )
      expect(entry.fetch(:teardown)).to include(reason: "retire host")
      expect(entry.dig(:teardown, :transport)).to include(
        host: "10.0.0.50",
        port: 22,
        target_path: "/srv/igniter/spark-crm",
        verified_shutdown: true
      )
      expect(entry.dig(:teardown, :acknowledged)).to be(true)
      expect(fake_session_class.commands.last).to include("rm -rf /srv/igniter/spark-crm")
      expect(fake_session_class.verifications.last).to include("pgrep -f /srv/igniter/spark-crm")
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("hp-call-analysis")).to be_nil
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("hp-call-analysis")).to be(false)
    end
  end

  it "can route local ignition through the real mesh admission workflow" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(mesh: Igniter::Cluster::Mesh, request_admission: true)
      entry = report.entries.first

      expect(report.status).to eq(:awaiting_admission)
      expect(entry).to include(
        target_id: "edge-1",
        status: :awaiting_admission_approval,
        action: :approve_cluster_admission
      )
      expect(entry.fetch(:admission)).to include(
        required: true,
        status: :awaiting_approval,
        outcome: :pending_approval
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :blocked_by_admission,
        node_id: "edge-1",
        peer_name: "edge-1"
      )
      expect(Igniter::Cluster::Mesh.pending_admissions.size).to eq(1)
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("edge-1")).to be(false)
    end
  end

  it "can auto-approve cluster admission for local ignition targets when requested" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true
      )
      entry = report.entries.first

      expect(report.status).to eq(:admitted)
      expect(entry).to include(
        target_id: "edge-1",
        status: :admitted,
        action: :start_local_runtime_unit
      )
      expect(entry.fetch(:admission)).to include(
        required: true,
        status: :admitted,
        outcome: :admitted
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :pending_runtime_boot
      )
      expect(Igniter::Cluster::Mesh.pending_admissions).to be_empty
      expect(Igniter::Cluster::Mesh.config.trust_store.known?("edge-1")).to be(true)
    end
  end

  it "can confirm a local ignition join for implicit local replicas" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
      YAML

      workspace = build_workspace(root: tmp)
      report = workspace.ignite
      joined = workspace.confirm_ignite_join(
        report: report,
        target_id: "edge-1",
        url: "http://127.0.0.1:4568"
      )
      entry = joined.entries.first

      expect(joined).to be_joined
      expect(entry).to include(
        target_id: "edge-1",
        status: :joined,
        action: :runtime_joined,
        url: "http://127.0.0.1:4568"
      )
      expect(entry.fetch(:admission)).to include(
        required: false,
        status: :implicit_local
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :joined,
        url: "http://127.0.0.1:4568"
      )
      expect(joined.by_join_status).to include(joined: 1)
    end
  end

  it "can confirm a cluster join after ignition admission and register the peer" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      report = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true
      )
      joined = workspace.confirm_ignite_join(
        report: report,
        target_id: "edge-1",
        url: "http://127.0.0.1:4568",
        mesh: Igniter::Cluster::Mesh,
        metadata: { role_hint: "analytics-edge" }
      )
      entry = joined.entries.first
      peer = Igniter::Cluster::Mesh.config.peer_registry.peer_named("edge-1")
      trail = Igniter::Cluster::Mesh.config.governance_trail.snapshot(limit: 5)

      expect(joined).to be_joined
      expect(entry).to include(
        target_id: "edge-1",
        status: :joined,
        action: :runtime_joined,
        url: "http://127.0.0.1:4568"
      )
      expect(entry.fetch(:admission)).to include(
        required: true,
        status: :admitted,
        outcome: :admitted
      )
      expect(entry.fetch(:join)).to include(
        required: true,
        status: :joined,
        url: "http://127.0.0.1:4568",
        peer_name: "edge-1",
        node_id: "edge-1"
      )
      expect(peer).not_to be_nil
      expect(peer.url).to eq("http://127.0.0.1:4568")
      expect(peer.capabilities).to eq([:audio_ingest])
      expect(peer.metadata.dig(:mesh_identity, :node_id)).to eq("edge-1")
      expect(peer.metadata.dig(:mesh_ignite, :target_id)).to eq("edge-1")
      expect(peer.metadata[:role_hint]).to eq("analytics-edge")
      expect(trail.fetch(:by_type)).to include(ignite_join_confirmed: 1)
    end
  end

  it "can detach a joined ignition target and unregister it from the active mesh" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
              capabilities:
                - audio_ingest
      YAML

      Igniter::Cluster::Mesh.configure do |c|
        c.peer_name = "seed-node"
        c.admission_policy = Igniter::Cluster::Governance::AdmissionPolicy.new(require_approval: true)
      end

      workspace = build_workspace(root: tmp)
      admitted = workspace.ignite(
        mesh: Igniter::Cluster::Mesh,
        request_admission: true,
        approve_pending_admission: true
      )
      joined = workspace.confirm_ignite_join(
        report: admitted,
        target_id: "edge-1",
        url: "http://127.0.0.1:4568",
        mesh: Igniter::Cluster::Mesh
      )

      detached = workspace.detach_ignite_target(
        report: joined,
        target_id: "edge-1",
        mesh: Igniter::Cluster::Mesh,
        metadata: { reason: "operator detach" }
      )
      entry = detached.entries.first

      expect(detached).to be_detached
      expect(entry).to include(
        target_id: "edge-1",
        status: :detached,
        action: :detached_from_cluster
      )
      expect(entry.fetch(:join)).to include(
        required: false,
        status: :detached
      )
      expect(entry.fetch(:detach)).to include(reason: "operator detach")
      expect(Igniter::Cluster::Mesh.config.peer_registry.peer_named("edge-1")).to be_nil
      expect(workspace.ignition_history(limit: 20).fetch(:by_type)).to include(intent_detached: 1)
    end
  end

  it "can reignite a detached target through a single-target ignition plan" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          approval: auto
          replicas:
            - name: edge-1
              port: 4568
            - name: edge-2
              port: 4569
      YAML

      workspace = build_workspace(root: tmp)
      joined = workspace.confirm_ignite_join(
        report: workspace.ignite,
        target_id: "edge-1",
        url: "http://127.0.0.1:4568"
      )
      detached = workspace.detach_ignite_target(report: joined, target_id: "edge-1")
      reignited = workspace.reignite_target(target_id: "edge-1")

      expect(detached.entries.find { |entry| entry[:target_id] == "edge-1" }).to include(
        status: :detached,
        action: :detached_from_cluster
      )
      expect(reignited.plan_id).to include(":expand:edge-1:")
      expect(reignited.entries.size).to eq(1)
      expect(reignited.entries.first).to include(
        target_id: "edge-1",
        status: :prepared,
        action: :start_local_runtime_unit
      )
      expect(reignited.summary).to include(total: 1, local_replicas: 1, remote_targets: 0)
    end
  end

  it "adds shared lib paths from both DSL and stack.yml" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "dsl_shared"))
      FileUtils.mkdir_p(File.join(tmp, "lib", "shared"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          shared_lib_paths:
            - lib/shared
      YAML

      workspace = build_workspace(root: tmp)
      workspace.shared_lib_path("dsl_shared")
      workspace.setup_load_paths!

      expect($LOAD_PATH).to include(File.join(tmp, "dsl_shared"))
      expect($LOAD_PATH).to include(File.join(tmp, "lib", "shared"))
    end
  end

  it "starts a named app directly when requested" do
    Dir.mktmpdir do |tmp|
      started = []
      main_app = Class.new(Igniter::App) do
        define_singleton_method(:start) { started << :main }
      end
      dashboard_app = Class.new(Igniter::App) do
        define_singleton_method(:start) { started << :dashboard }
      end

      workspace = build_workspace(
        root: tmp,
        app_classes: { main: main_app, dashboard: dashboard_app }
      )

      workspace.start(:dashboard)

      expect(started).to eq([:dashboard])
    end
  end

  it "starts a node from CLI args with env selection" do
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "config", "environments"))
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
          default_node: seed
        nodes:
          seed:
            port: 4667
          edge:
            port: 4668
      YAML
      File.write(File.join(tmp, "config", "environments", "production.yml"), <<~YAML)
        nodes:
          edge:
            port: 5668
      YAML

      started = []
      fake_host = double("host", start: nil, activate_transport!: nil)
      root_app = Class.new(Igniter::App) do
        define_singleton_method(:host_adapter) { fake_host }
        define_singleton_method(:send) do |method_name, *_args|
          case method_name
          when :build!
            started << :build
            OpenStruct.new(custom_routes: [], host_settings: {}, host: nil, port: nil, log_format: nil, drain_timeout: nil)
          when :start_scheduler
            nil
          else
            super(method_name)
          end
        end
      end

      workspace = build_workspace(root: tmp, environment: "production", app_classes: { main: root_app, dashboard: Class.new(Igniter::App) })
      workspace.start_cli(%w[--node edge])

      expect(workspace.environment).to eq("production")
      expect(workspace.node_profile(:edge).fetch("port")).to eq(5668)
      expect(started).to eq([:build])
    end
  end

  it "builds a deployment snapshot for registered apps and nodes" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: demo_workspace
          root_app: dashboard
          default_node: edge
        server:
          host: 0.0.0.0
        nodes:
          edge:
            port: 4668
            role: edge
      YAML

      workspace = build_workspace(root: tmp)
      workspace.mount(:main, at: "/main")
      snapshot = workspace.deployment_snapshot

      expect(snapshot.dig("stack", "root_app")).to eq("dashboard")
      expect(snapshot.dig("stack", "default_node")).to eq("edge")
      expect(snapshot.dig("stack", "mounts")).to eq("main" => "/main")
      expect(snapshot.dig("apps", "main")).to include(
        "app" => "main",
        "root" => false
      )
      expect(snapshot.dig("apps", "dashboard")).to include(
        "app" => "dashboard",
        "root" => true
      )
      expect(snapshot.dig("nodes", "edge")).to include(
        "node" => "edge",
        "role" => "edge",
        "port" => 4668,
        "default" => true
      )
    end
  end

  it "supports explicit cross-app access through expose, access_to, and interface" do
    Dir.mktmpdir do |tmp|
      notes_interface = -> { { "ok" => true } }
      main_app = Class.new(Igniter::App) do
        provide :notes_api, notes_interface
      end
      dashboard_app = Class.new(Igniter::App)

      workspace = Class.new(described_class).tap do |stack|
        stack.root_dir(tmp)
        stack.app :main, path: "apps/main", klass: main_app, default: true
        stack.app :dashboard, path: "apps/dashboard", klass: dashboard_app, access_to: [:notes_api]
      end

      expect { workspace.send(:validate_interface_access!) }.not_to raise_error
      expect(workspace.interface(:notes_api)).to be(notes_interface)
      expect(workspace.interface(:notes_api).call).to eq("ok" => true)
      expect(workspace.interfaces).to include(notes_api: notes_interface)
    end
  end

  it "fails fast when access_to declares an interface that no app exposes" do
    Dir.mktmpdir do |tmp|
      workspace = build_workspace(root: tmp)
      workspace.app :dashboard, path: "apps/dashboard", klass: Class.new(Igniter::App), access_to: [:notes_api]

      expect { workspace.send(:validate_interface_access!) }
        .to raise_error(ArgumentError, /declares access_to :notes_api .*Known interfaces: \[\]/)
    end
  end

  it "generates a compose config from stack node settings" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: companion
          root_app: main
          default_node: seed
        server:
          host: 0.0.0.0
        shared:
          environment:
            SHARED_FLAG: "1"
        deploy:
          compose:
            context: ../../../../
            dockerfile: examples/companion/config/deploy/Dockerfile
            working_dir: /app/examples/companion
            volume_name: companion_var
            volume_target: /app/examples/companion/var
            environment:
              APP_MODE: mesh
        nodes:
          seed:
            public: true
            port: 4567
            depends_on:
              - edge
            environment:
              NODE_KIND: seed
          edge:
            public: false
            port: 4568
      YAML

      workspace = build_workspace(root: tmp, environment: "production")
      compose = workspace.compose_config

      expect(compose.dig("services", "seed", "build")).to eq(
        "context" => "../../../../",
        "dockerfile" => "examples/companion/config/deploy/Dockerfile"
      )
      expect(compose.dig("services", "seed", "environment")).to include(
        "APP_MODE" => "mesh",
        "SHARED_FLAG" => "1",
        "IGNITER_NODE" => "seed",
        "IGNITER_ROOT_APP" => "main",
        "IGNITER_ENV" => "production",
        "PORT" => "4567",
        "NODE_KIND" => "seed"
      )
      expect(compose.dig("services", "seed", "ports")).to eq(["4567:4567"])
      expect(compose.dig("services", "seed", "depends_on")).to eq(["edge"])
      expect(compose.dig("services", "seed", "volumes")).to eq(
        ["companion_var:/app/examples/companion/var"]
      )
      expect(compose.fetch("volumes")).to include("companion_var" => {})
      expect(workspace.compose_yaml).to include("services:")
      expect(workspace.compose_yaml).to include("companion_var")
    end
  end

  it "writes generated compose yaml to the configured path" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: write_test
        nodes:
          main:
            public: true
            port: 4567
      YAML

      workspace = build_workspace(root: tmp)
      path = workspace.write_compose

      expect(path).to eq(File.join(tmp, "config", "deploy", "compose.yml"))
      expect(File.read(path)).to include("services:")
      expect(File.read(path)).to include("main:")
    end
  end

  it "generates a Procfile.dev for local node-based development" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: home_lab
          root_app: main
          default_node: seed
        shared:
          environment:
            SHARED_FLAG: "1"
        nodes:
          seed:
            port: 4567
          edge:
            command: bundle exec ruby stack.rb --node edge
            environment:
              EDGE_MODE: enabled
            port: 4569
      YAML

      workspace = build_workspace(root: tmp, environment: "development")
      procfile = workspace.procfile_dev

      expect(procfile).to include("seed:")
      expect(procfile).to include("edge:")
      expect(procfile).to include("RUBYOPT=")
      expect(procfile).to include("dev_output_sync")
      expect(procfile).to include("SHARED_FLAG=1")
      expect(procfile).to include("EDGE_MODE=enabled")
      expect(procfile).to include("IGNITER_NODE=edge")
      expect(procfile).to include("bundle exec ruby stack.rb --node edge")
    end
  end

  it "treats ignite replicas as synthetic local runtime units when nodes are absent" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          name: spark_crm
          root_app: main
        server:
          host: 0.0.0.0
          port: 4567
        ignite:
          replicas:
            - name: edge-1
              port: 4568
            - name: edge-2
              port: 4569
      YAML

      workspace = build_workspace(root: tmp, environment: "development")
      services = workspace.dev_services
      procfile = workspace.procfile_dev
      snapshot = workspace.deployment_snapshot

      expect(services.map { |service| service.fetch(:name) }).to eq(%w[main edge-1 edge-2])
      expect(services[1].fetch(:environment)).to include(
        "IGNITER_NODE" => "edge-1",
        "IGNITER_IGNITE_REPLICA" => "true",
        "PORT" => "4568"
      )
      expect(services[2].fetch(:environment)).to include(
        "IGNITER_NODE" => "edge-2",
        "IGNITER_IGNITE_REPLICA" => "true",
        "PORT" => "4569"
      )
      expect(procfile).to include("edge-1:")
      expect(procfile).to include("edge-2:")
      expect(snapshot.dig("nodes", "edge-1", "port")).to eq(4568)
      expect(snapshot.dig("nodes", "edge-2", "port")).to eq(4569)
    end
  end

  it "writes generated Procfile.dev to the configured path" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        nodes:
          main:
            port: 4567
      YAML

      workspace = build_workspace(root: tmp)
      path = workspace.write_procfile_dev

      expect(path).to eq(File.join(tmp, "config", "deploy", "Procfile.dev"))
      expect(File.read(path)).to include("main:")
    end
  end

  it "mounts apps behind the stack runtime" do
    root_app = Class.new(Igniter::App) do
      route "GET", "/hello" do
        { source: "main" }
      end
    end

    mounted_app = Class.new(Igniter::App) do
      route "GET", "/hello" do
        { source: "dashboard" }
      end
    end

    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
      YAML

      workspace = build_workspace(
        root: tmp,
        app_classes: { main: root_app, dashboard: mounted_app }
      )
      workspace.mount(:dashboard, at: "/dashboard")

      rack_app = workspace.rack_app
      root_status, _root_headers, root_body = rack_app.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/hello",
        "rack.input" => StringIO.new("")
      )
      mounted_status, _mounted_headers, mounted_body = rack_app.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/dashboard/hello",
        "rack.input" => StringIO.new("")
      )

      expect(root_status).to eq(200)
      expect(root_body.join).to include("\"source\":\"main\"")
      expect(mounted_status).to eq(200)
      expect(mounted_body.join).to include("\"source\":\"dashboard\"")
    end
  end

  it "builds local node profiles from stack.yml" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
          default_node: seed
        server:
          host: 0.0.0.0
        nodes:
          seed:
            port: 4667
            role: seed
            environment:
              NODE_KIND: seed
          edge:
            port: 4668
            role: edge
      YAML

      workspace = build_workspace(root: tmp)
      workspace.mount(:dashboard, at: "/dashboard")
      snapshot = workspace.deployment_snapshot
      procfile = workspace.procfile_dev

      expect(workspace.root_app).to eq(:main)
      expect(workspace.default_node).to eq(:seed)
      expect(workspace.node_names).to eq(%i[seed edge])
      expect(snapshot.dig("stack", "default_node")).to eq("seed")
      expect(snapshot.dig("nodes", "seed", "port")).to eq(4667)
      expect(snapshot.dig("nodes", "seed", "mounts")).to eq("dashboard" => "/dashboard")
      expect(procfile).to include("seed:")
      expect(procfile).to include("IGNITER_NODE=seed")
      expect(procfile).to include("bundle exec ruby stack.rb --node seed")
      expect(procfile).to include("NODE_KIND=seed")
    end
  end

  it "writes per-node dev logs to var/log/dev by default" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
        nodes:
          seed:
            command: ruby -e 'puts "hello from seed"; warn "warn from seed"'
            port: 4667
      YAML

      workspace = build_workspace(root: tmp)
      workspace.start_dev

      log_path = File.join(tmp, "var", "log", "dev", "seed.log")
      expect(File.exist?(log_path)).to be(true)

      log = File.read(log_path)
      expect(log).to include("# igniter dev log")
      expect(log).to include("[seed] hello from seed")
      expect(log).to include("[seed] warn from seed")
    end
  end

  it "builds a console context with stack, app, node, and runtime helpers" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
          default_node: edge
        nodes:
          edge:
            port: 4668
      YAML

      workspace = build_workspace(root: tmp)
      workspace.mount(:dashboard, at: "/dashboard")

      context = workspace.console_context(:dashboard, node: :edge)
      bind = workspace.console_binding(:dashboard, node: :edge)

      expect(context.stack_class).to eq(workspace)
      expect(context.root_app_name).to eq(:main)
      expect(context.app_name).to eq(:dashboard)
      expect(context.node_name).to eq(:edge)
      expect(context.node_profile).to include("port" => 4668)
      expect(context.deployment.dig("stack", "root_app")).to eq("main")
      expect(context.mounts).to eq(dashboard: "/dashboard")
      expect(bind.local_variable_get(:stack)).to eq(workspace)
      expect(bind.local_variable_get(:app_name)).to eq(:dashboard)
      expect(bind.local_variable_get(:node_name)).to eq(:edge)
      expect(bind.local_variable_get(:deployment).dig("stack", "default_node")).to eq("edge")
    end
  end

  it "routes CLI console mode into start_console" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
          default_node: edge
        nodes:
          edge:
            port: 4668
      YAML

      workspace = build_workspace(root: tmp)

      expect(workspace).to receive(:start_console).with("dashboard", node: "edge", environment: "development", evaluate: nil)
      workspace.start_cli(%w[--console --node edge --env development dashboard])
    end
  end

  it "prints stack-oriented CLI help" do
    Dir.mktmpdir do |tmp|
      workspace = build_workspace(root: tmp)

      expect do
        begin
          workspace.start_cli(%w[--help])
        rescue SystemExit
          nil
        end
      end.to output(
        include(
          "Usage: stack.rb [app] [options]",
          "Stack-first runtime surface:",
          "Canonical wrappers:",
          "bin/console",
          "--console",
          "--dev",
          "stack.rb --console --node seed",
          "var/log/dev/*.log"
        )
      ).to_stdout
    end
  end

  it "evaluates code inside the stack console and exits" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
          default_node: seed
        nodes:
          seed:
            port: 4667
      YAML

      workspace = build_workspace(root: tmp)
      output = StringIO.new
      result = workspace.start_console(:dashboard, node: :seed, output: output, evaluate: "[app_name, node_name, root_app_name]")

      expect(result).to eq(%i[dashboard seed main])
      expect(output.string).to include("Igniter Console")
      expect(output.string).to include("=> [:dashboard, :seed, :main]")
    end
  end

  it "starts one mounted stack runtime in dev mode when nodes are absent" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        stack:
          root_app: main
      YAML

      workspace = build_workspace(root: tmp)
      workspace.mount(:dashboard, at: "/dashboard")

      expect(workspace.dev_services).to eq([
        {
          name: "main",
          command: "bundle exec ruby stack.rb",
          environment: { "IGNITER_ROOT_APP" => "main", "RUBYOPT" => workspace.send(:rubyopt_with_dev_output_sync) }
        }
      ])
    end
  end

  it "lets PORT override stack server port for runtime boot" do
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "stack.yml"), <<~YAML)
        server:
          host: 0.0.0.0
          port: 4567
      YAML

      workspace = build_workspace(root: tmp)
      ENV["PORT"] = "5567"

      expect(workspace.send(:stack_http_settings)).to include("host" => "0.0.0.0", "port" => 5567)
    end
  end
end
