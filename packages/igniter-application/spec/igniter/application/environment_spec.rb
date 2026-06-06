# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../../spec_helper"

RSpec.describe Igniter::Application::Environment do
  class LifecycleScheduler
    attr_reader :starts, :stops

    def initialize
      @starts = []
      @stops = []
    end

    def start(environment:)
      @starts << environment.profile.scheduler_name
      self
    end

    def stop(environment:)
      @stops << environment.profile.scheduler_name
      self
    end
  end

  class LifecycleLoader
    attr_reader :loads

    def initialize
      @loads = []
    end

    def load!(base_dir:, paths:, environment:)
      @loads << {
        base_dir: base_dir.to_s,
        paths: paths,
        loader: environment.profile.loader_name
      }
      self
    end
  end

  class LifecycleHost
    attr_reader :activations, :deactivations

    def initialize
      @activations = 0
      @deactivations = 0
    end

    def activate!(environment:)
      @activations += 1
      environment
    end

    def deactivate!(environment:)
      @deactivations += 1
      environment
    end

    def start(environment:)
      environment.snapshot
    end

    def rack_app(_environment:)
      ->(_env) { [200, { "content-type" => "text/plain" }, ["LifecycleHost"]] }
    end
  end

  class LifecycleProvider < Igniter::Application::Provider
    attr_reader :boot_calls, :shutdown_calls

    def initialize
      @boot_calls = 0
      @shutdown_calls = 0
    end

    def services(environment:)
      endpoint = environment.config.fetch(:services, :analytics, :endpoint)
      {
        analytics_api: -> { endpoint }
      }
    end

    def interfaces(environment:)
      endpoint = environment.config.fetch(:services, :analytics, :endpoint)
      {
        public_analytics_api: Igniter::Application::Interface.new(
          name: :public_analytics_api,
          callable: -> { endpoint },
          metadata: { audience: :external },
          source: :analytics
        )
      }
    end

    def boot(environment:)
      @boot_calls += 1
      environment.config.fetch(:runtime, :mode)
    end

    def shutdown(environment:)
      @shutdown_calls += 1
      environment.config.fetch(:runtime, :mode)
    end
  end

  def activation_evidence_packet(dry_run:, readiness:, digest:, idempotency_key: "activation-key-1")
    {
      packet_id: "activation-packet-1",
      schema_version: "activation-ledger-v1",
      transfer_receipt_id: "transfer-receipt-1",
      activation_readiness_id: "activation-readiness-1",
      activation_plan_id: "activation-plan-1",
      activation_plan_verification_id: "activation-plan-verification-1",
      activation_dry_run_id: "activation-dry-run-1",
      commit_readiness_id: "activation-commit-readiness-1",
      operation_digest: digest,
      commit_decision: true,
      idempotency_key: idempotency_key,
      caller_metadata: { source: :spec },
      receipt_sink: "activation-ledger",
      application_host_adapter: { name: :file_backed_host_activation_ledger },
      dry_run: dry_run,
      commit_readiness: readiness
    }
  end

  class ActivationLedgerReadbackProbe
    def initialize(records)
      @records = records
    end

    def readback(idempotency_key:, operation_digest: nil)
      @records.select do |record|
        record[:idempotency_key] == idempotency_key ||
          record["idempotency_key"] == idempotency_key ||
          operation_digest
      end
    end
  end

  it "publishes an application manifest and canonical layout through the profile" do
    root = File.expand_path("/tmp/igniter_shop")
    profile = Igniter::Application.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                                  .manifest(:shop, root: root, env: :test, metadata: { owner: :commerce })
                                  .providers_path("app/providers")
                                  .services_path("app/services")
                                  .effects_path("app/effects")
                                  .packs_path("app/packs")
                                  .contracts_path("app/contracts")
                                  .config_path("config/igniter.rb")
                                  .set(:runtime, :mode, value: :test)
                                  .provide(:pricing_api, -> { :ok })
                                  .expose(:public_pricing_api, -> { :ok }, metadata: { audience: :public })
                                  .register("PricingContract", Object)
                                  .finalize
    environment = described_class.new(profile: profile)

    expect(environment.manifest.to_h).to include(
      name: :shop,
      root: root,
      env: :test,
      packs: include("Igniter::Extensions::Contracts::ComposePack"),
      contracts: ["PricingContract"],
      services: %i[pricing_api public_pricing_api],
      interfaces: [:public_pricing_api],
      config: include(runtime: { mode: :test }),
      metadata: { owner: :commerce }
    )
    expect(environment.layout.to_h).to include(
      root: root,
      paths: include(
        contracts: "app/contracts",
        providers: "app/providers",
        services: "app/services",
        effects: "app/effects",
        packs: "app/packs",
        config: "config/igniter.rb",
        spec: "spec/igniter"
      ),
      absolute_paths: include(
        contracts: File.join(root, "app/contracts"),
        config: File.join(root, "config/igniter.rb")
      )
    )
    expect(profile.to_h.fetch(:manifest)).to include(
      name: :shop,
      layout: include(paths: include(contracts: "app/contracts"))
    )
    expect(environment.snapshot.to_h.fetch(:manifest)).to include(name: :shop, env: :test)
  end

  it "reports application layout paths during code loading" do
    Dir.mktmpdir("igniter-shop") do |root|
      FileUtils.mkdir_p(File.join(root, "app/contracts"))
      FileUtils.mkdir_p(File.join(root, "app/services"))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/igniter.rb"), "# test config\n")

      environment = Igniter::Application.build_kernel
                                        .manifest(:shop, root: root, env: :test)
                                        .contracts_path("app/contracts")
                                        .services_path("app/services")
                                        .effects_path("app/effects")
                                        .config_path("config/igniter.rb")
                                        .then { |kernel| described_class.new(profile: kernel.finalize) }

      report = environment.boot(base_dir: root, start_scheduler: false)
      load_report = report.loader_result.metadata.fetch(:load_report)

      expect(load_report).to include(
        base_dir: root,
        present_groups: %i[config contracts services],
        missing_groups: [:effects],
        present_count: 3,
        missing_count: 1
      )
      expect(load_report.fetch(:entries)).to include(
        include(group: :contracts, path: "app/contracts", kind: :directory, status: :present),
        include(group: :services, path: "app/services", kind: :directory, status: :present),
        include(group: :config, path: "config/igniter.rb", kind: :file, status: :present),
        include(group: :effects, path: "app/effects", kind: :missing, status: :missing)
      )
      expect(environment.snapshot.to_h.fetch(:runtime).fetch(:application_load_report)).to include(
        present_groups: %i[config contracts services],
        missing_groups: [:effects]
      )
    end
  end

  it "builds application blueprints before applying them to a runtime kernel" do
    root = File.expand_path("/tmp/igniter_blueprint_shop")
    blueprint = Igniter::Application.blueprint(
      name: :shop,
      root: root,
      env: :test,
      packs: ["Igniter::Extensions::Contracts::ComposePack"],
      contracts: ["PricingContract"],
      services: [:pricing_api],
      effects: [:journal],
      web_surfaces: [:operator_console],
      config: { runtime: { mode: :test } },
      metadata: { owner: :commerce }
    )

    expect(blueprint.to_h).to include(
      name: :shop,
      root: root,
      env: :test,
      contracts: ["PricingContract"],
      services: [:pricing_api],
      effects: [:journal],
      web_surfaces: [:operator_console],
      metadata: { owner: :commerce },
      planned_paths: include(
        include(group: :contracts, path: "app/contracts", kind: :directory),
        include(group: :config, path: "config/igniter.rb", kind: :file)
      )
    )
    expect(blueprint.to_manifest.to_h).to include(
      name: :shop,
      env: :test,
      metadata: include(blueprint: true, web_surfaces: [:operator_console])
    )

    profile = Igniter::Application.build_kernel
                                  .apply_blueprint(blueprint)
                                  .finalize
    environment = described_class.new(profile: profile)

    expect(environment.manifest.to_h).to include(
      name: :shop,
      root: root,
      env: :test,
      metadata: include(
        owner: :commerce,
        blueprint: true,
        effects: [:journal],
        web_surfaces: [:operator_console]
      ),
      config: include(runtime: { mode: :test })
    )
    expect(environment.layout.path(:contracts)).to eq("app/contracts")
  end

  it "plans and materializes application structure from blueprints explicitly" do
    Dir.mktmpdir("igniter-structure") do |root|
      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: root,
        env: :test,
        web_surfaces: [:operator_console]
      )

      plan = blueprint.structure_plan(metadata: { source: :spec })

      expect(plan.to_h).to include(
        root: root,
        blueprint: :operator,
        mode: :sparse,
        layout_profile: :standalone,
        present_count: 0,
        missing_count: 3,
        metadata: { source: :spec }
      )
      expect(plan.to_h.fetch(:entries)).to include(
        include(group: :web, kind: :directory, status: :missing, action: :create_directory),
        include(group: :config, kind: :file, status: :missing, action: :write_file)
      )

      result = blueprint.materialize_structure!

      expect(result).to include(
        root: root,
        applied_count: 3,
        applied_groups: %i[config spec web]
      )
      expect(File.directory?(File.join(root, "app/web"))).to be(true)
      expect(File.file?(File.join(root, "config/igniter.rb"))).to be(true)

      refreshed = blueprint.structure_plan
      expect(refreshed.to_h).to include(
        present_count: 3,
        missing_count: 0,
        present_groups: %i[config spec web]
      )

      complete_result = blueprint.materialize_structure!(mode: :complete)
      expect(complete_result).to include(
        root: root,
        applied_count: 10,
        applied_groups: %i[agents contracts effects executors packs providers services skills support tools]
      )

      complete_plan = blueprint.structure_plan(mode: :complete)
      expect(complete_plan.to_h).to include(
        mode: :complete,
        present_count: 13,
        missing_count: 0
      )
    end
  end

  it "builds read-only capsule transfer inventories from declared layout paths" do
    Dir.mktmpdir("igniter-transfer-inventory") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))
      FileUtils.mkdir_p(File.join(root, "services"))
      File.write(File.join(root, "contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "services/incident_queue.rb"), "# service\n")

      capsule = Igniter::Application.capsule(:operator, root: root, env: :test) do
        layout :capsule
        groups :contracts, :services
        web_surface :operator_console
      end

      inventory = Igniter::Application.transfer_inventory(
        capsule,
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ],
        metadata: { source: :spec }
      )
      payload = inventory.to_h
      capsule_payload = payload.fetch(:capsules).first

      expect(payload).to include(
        ready: false,
        capsule_count: 1,
        expected_path_count: 5,
        existing_path_count: 2,
        missing_path_count: 3,
        file_count: 2,
        metadata: { source: :spec }
      )
      expect(capsule_payload).to include(
        name: :operator,
        root: root,
        layout_profile: :capsule,
        active_groups: %i[config contracts services spec web],
        file_count: 2
      )
      expect(capsule_payload.fetch(:expected_paths)).to include(
        include(group: :contracts, path: "contracts", kind: :directory, status: :present),
        include(group: :config, path: "igniter.rb", kind: :file, status: :missing)
      )
      expect(capsule_payload.fetch(:missing_expected_paths).map { |entry| entry.fetch(:group) }).to eq(%i[config spec web])
      expect(capsule_payload.fetch(:files)).to include(
        include(group: :contracts, relative_path: "contracts/resolve_incident.rb"),
        include(group: :services, relative_path: "services/incident_queue.rb")
      )
      expect(capsule_payload.fetch(:surfaces)).to contain_exactly(
        include(name: :operator_console, kind: :web_surface, path: "web")
      )
    end
  end

  it "can defer transfer inventory file enumeration" do
    Dir.mktmpdir("igniter-transfer-inventory") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: root,
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts]
      )

      payload = Igniter::Application.transfer_inventory(blueprint, enumerate_files: false).to_h
      capsule_payload = payload.fetch(:capsules).first

      expect(payload).to include(files_enumerated: false, file_count: :not_enumerated)
      expect(capsule_payload).to include(files_enumerated: false, files: :not_enumerated, file_count: :not_enumerated)
    end
  end

  it "builds transfer readiness reports over handoff manifests and inventories" do
    Dir.mktmpdir("igniter-transfer-readiness") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))
      File.write(File.join(root, "contracts/resolve_incident.rb"), "# contract\n")

      capsule = Igniter::Application.capsule(:operator, root: root, env: :test) do
        layout :capsule
        groups :contracts, :services
        export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
        import :incident_runtime, kind: :service, from: :host
        import :audit_log, kind: :service, from: :host, optional: true
        web_surface :operator_console
      end

      report = Igniter::Application.transfer_readiness(
        capsule,
        subject: :operator_bundle,
        metadata: { source: :spec }
      ).to_h

      expect(report).to include(ready: false, metadata: { source: :spec })
      expect(report.fetch(:blockers).map { |entry| entry.fetch(:code) }).to include(
        :unresolved_required_import,
        :missing_expected_path
      )
      expect(report.fetch(:warnings).map { |entry| entry.fetch(:code) }).to include(
        :missing_optional_import,
        :surface_metadata_absent
      )
      expect(report.fetch(:summary)).to include(
        manifest_ready: false,
        inventory_ready: false,
        unresolved_required_count: 1,
        supplied_surface_count: 0
      )
      expect(report.fetch(:summary).fetch(:sources)).to include(
        manifest: 2,
        inventory: 4,
        surface_metadata: 1
      )
    end
  end

  it "accepts explicit transfer artifacts and policy for missing paths" do
    Dir.mktmpdir("igniter-transfer-readiness") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: root,
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      manifest = Igniter::Application.handoff_manifest(
        subject: :operator_bundle,
        capsules: [blueprint],
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      inventory = Igniter::Application.transfer_inventory(blueprint, enumerate_files: false)

      report = Igniter::Application.transfer_readiness(
        handoff_manifest: manifest,
        transfer_inventory: inventory,
        policy: { missing_expected_paths: :warning }
      ).to_h

      expect(report).to include(ready: true)
      expect(report.fetch(:blockers)).to eq([])
      expect(report.fetch(:warnings).map { |entry| entry.fetch(:code) }).to include(
        :missing_expected_path,
        :files_not_enumerated
      )
      expect(report.fetch(:summary)).to include(
        manifest_ready: true,
        inventory_ready: false,
        unresolved_required_count: 0
      )
    end
  end

  it "builds read-only transfer bundle plans over readiness and inventory" do
    Dir.mktmpdir("igniter-transfer-bundle") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))
      FileUtils.mkdir_p(File.join(root, "services"))
      File.write(File.join(root, "contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "services/incident_queue.rb"), "# service\n")

      capsule = Igniter::Application.capsule(:operator, root: root, env: :test) do
        layout :capsule
        groups :contracts, :services
        export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
        import :incident_runtime, kind: :service, from: :host
        web_surface :operator_console
      end
      surface_metadata = [
        { name: :operator_console, kind: :web_surface, path: "web" }
      ]

      plan = Igniter::Application.transfer_bundle_plan(
        capsule,
        subject: :operator_bundle,
        surface_metadata: surface_metadata,
        metadata: { source: :spec }
      ).to_h

      expect(plan).to include(
        subject: :operator_bundle,
        ready: false,
        bundle_allowed: false,
        included_file_count: 2,
        missing_path_count: 3,
        metadata: { source: :spec }
      )
      expect(plan.fetch(:capsules)).to contain_exactly(
        include(name: :operator, file_count: 2, missing_path_count: 3, skipped_path_count: 0)
      )
      expect(plan.fetch(:included_files)).to include(
        include(capsule: :operator, relative_path: "contracts/resolve_incident.rb"),
        include(capsule: :operator, relative_path: "services/incident_queue.rb")
      )
      expect(plan.fetch(:missing_paths).map { |entry| entry.fetch(:group) }).to eq(%i[config spec web])
      expect(plan.fetch(:surfaces)).to contain_exactly(
        include(name: :operator_console, kind: :web_surface, path: "web")
      )
      expect(plan.fetch(:blockers).map { |entry| entry.fetch(:code) }).to include(
        :unresolved_required_import,
        :missing_expected_path
      )
      expect(plan.fetch(:policy)).to eq(allow_not_ready: false)
      expect(plan.fetch(:readiness)).to include(ready: false)
    end
  end

  it "can produce review-only transfer bundle plans for not-ready transfers" do
    Dir.mktmpdir("igniter-transfer-bundle") do |root|
      FileUtils.mkdir_p(File.join(root, "contracts"))

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: root,
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      readiness = Igniter::Application.transfer_readiness(
        blueprint,
        subject: :operator_bundle,
        policy: { missing_expected_paths: :warning }
      )

      plan = Igniter::Application.transfer_bundle_plan(
        transfer_readiness: readiness,
        policy: { allow_not_ready: true }
      ).to_h

      expect(plan).to include(
        subject: :operator_bundle,
        ready: false,
        bundle_allowed: true,
        policy: { allow_not_ready: true }
      )
      expect(plan.fetch(:blockers).map { |entry| entry.fetch(:code) }).to eq([:unresolved_required_import])
      expect(plan.fetch(:warnings).map { |entry| entry.fetch(:code) }).to include(:missing_expected_path)
    end
  end

  it "writes explicit transfer bundle artifacts from allowed bundle plans" do
    Dir.mktmpdir("igniter-transfer-artifact") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        metadata: { source: :spec }
      )
      output = File.join(root, "operator_bundle")

      result = Igniter::Application.write_transfer_bundle(
        plan,
        output: output,
        metadata: { requested_by: :spec }
      )
      payload = result.to_h

      expect(payload).to include(
        written: true,
        artifact_path: output,
        included_file_count: 2,
        metadata_entry: "igniter-transfer-bundle.json",
        refusals: [],
        metadata: { requested_by: :spec }
      )
      expect(File.file?(File.join(output, "files/operator/contracts/resolve_incident.rb"))).to be(true)
      expect(File.file?(File.join(output, "files/operator/igniter.rb"))).to be(true)

      manifest = JSON.parse(File.read(File.join(output, "igniter-transfer-bundle.json")), symbolize_names: true)
      expect(manifest).to include(
        kind: "igniter_transfer_bundle",
        subject: "operator_bundle",
        bundle_allowed: true,
        included_file_count: 2,
        metadata_entry: "igniter-transfer-bundle.json",
        files_root: "files",
        metadata: { requested_by: "spec" }
      )
      expect(manifest.fetch(:plan)).to include(subject: "operator_bundle", bundle_allowed: true)
    end
  end

  it "refuses transfer bundle artifacts when policy or output validation blocks writing" do
    Dir.mktmpdir("igniter-transfer-artifact") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle
      )
      output = File.join(root, "operator_bundle")

      result = Igniter::Application.write_transfer_bundle(plan, output: output).to_h

      expect(result).to include(
        written: false,
        artifact_path: output,
        included_file_count: 0,
        metadata_entry: nil
      )
      expect(result.fetch(:refusals).map { |entry| entry.fetch(:code) }).to eq([:bundle_not_allowed])
      expect(File.exist?(output)).to be(false)
    end
  end

  it "verifies transfer bundle artifacts without extracting or installing them" do
    Dir.mktmpdir("igniter-transfer-verify") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      output = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: output)

      report = Igniter::Application.verify_transfer_bundle(output, metadata: { source: :spec }).to_h

      expect(report).to include(
        valid: true,
        artifact_path: output,
        metadata_entry: "igniter-transfer-bundle.json",
        missing_files: [],
        extra_files: [],
        malformed_entries: [],
        included_file_count: 2,
        actual_file_count: 2,
        surface_count: 1,
        metadata: { source: :spec }
      )
    end
  end

  it "reports transfer bundle verification mismatches read-only" do
    Dir.mktmpdir("igniter-transfer-verify") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      output = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: output)
      FileUtils.rm_f(File.join(output, "files/operator/igniter.rb"))
      File.write(File.join(output, "files/operator/extra.txt"), "extra\n")

      report = Igniter::Application.verify_transfer_bundle(output).to_h

      expect(report).to include(valid: false, included_file_count: 2, actual_file_count: 2)
      expect(report.fetch(:missing_files)).to eq(["files/operator/igniter.rb"])
      expect(report.fetch(:extra_files)).to eq(["files/operator/extra.txt"])
      expect(report.fetch(:malformed_entries)).to eq([])
    end
  end

  it "plans transfer bundle intake into an explicit destination without copying" do
    Dir.mktmpdir("igniter-transfer-intake") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      destination = File.join(root, "destination")

      intake = Igniter::Application.transfer_intake_plan(
        verification,
        destination_root: destination,
        metadata: { source: :spec }
      ).to_h

      expect(intake).to include(
        ready: true,
        destination_root: destination,
        artifact_path: artifact,
        verification_valid: true,
        conflicts: [],
        blockers: [],
        required_host_wiring: [],
        surface_count: 1,
        metadata: { source: :spec }
      )
      expect(intake.fetch(:planned_files)).to include(
        include(
          capsule: :operator,
          artifact_path: "files/operator/contracts/resolve_incident.rb",
          destination_relative_path: "operator/contracts/resolve_incident.rb",
          status: :planned,
          safe: true
        ),
        include(
          capsule: :operator,
          artifact_path: "files/operator/igniter.rb",
          destination_relative_path: "operator/igniter.rb",
          status: :planned,
          safe: true
        )
      )
      expect(File.exist?(File.join(destination, "operator/contracts/resolve_incident.rb"))).to be(false)
    end
  end

  it "reports destination conflicts during transfer intake planning" do
    Dir.mktmpdir("igniter-transfer-intake") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      destination = File.join(root, "destination")
      FileUtils.mkdir_p(File.join(destination, "operator/contracts"))
      File.write(File.join(destination, "operator/contracts/resolve_incident.rb"), "# existing\n")

      intake = Igniter::Application.transfer_intake_plan(
        artifact,
        destination_root: destination
      ).to_h

      expect(intake).to include(ready: false, verification_valid: true)
      expect(intake.fetch(:conflicts)).to contain_exactly(
        include(
          code: :destination_exists,
          destination_relative_path: "operator/contracts/resolve_incident.rb"
        )
      )
      expect(intake.fetch(:blockers).map { |entry| entry.fetch(:code) }).to eq([:destination_conflict])
    end
  end

  it "keeps transfer intake planning report-shaped for invalid bundle metadata" do
    Dir.mktmpdir("igniter-transfer-intake") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      metadata_path = File.join(artifact, "igniter-transfer-bundle.json")
      manifest = JSON.parse(File.read(metadata_path), symbolize_names: true)
      manifest.fetch(:plan).fetch(:included_files) << { relative_path: "../escape.rb" }
      File.write(metadata_path, JSON.pretty_generate(manifest))

      intake = Igniter::Application.transfer_intake_plan(
        artifact,
        destination_root: File.join(root, "destination")
      ).to_h

      expect(intake).to include(ready: false, verification_valid: false)
      expect(intake.fetch(:planned_files)).to include(include(status: :unsafe, safe: false))
      expect(intake.fetch(:blockers).map { |entry| entry.fetch(:code) }).to include(
        :verification_invalid,
        :unsafe_destination_path
      )
    end
  end

  it "plans transfer apply operations over accepted intake data without mutating" do
    Dir.mktmpdir("igniter-transfer-apply") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      destination = File.join(root, "destination")
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)

      apply_plan = Igniter::Application.transfer_apply_plan(intake, metadata: { source: :spec }).to_h

      expect(apply_plan).to include(
        executable: true,
        artifact_path: artifact,
        destination_root: destination,
        operation_count: 4,
        blockers: [],
        warnings: [],
        surface_count: 1,
        metadata: { source: :spec }
      )
      expect(apply_plan.fetch(:operations)).to eq(
        [
          {
            type: :ensure_directory,
            status: :planned,
            source: nil,
            destination: "operator",
            metadata: { reason: :file_parent, file_count: 1 }
          },
          {
            type: :ensure_directory,
            status: :planned,
            source: nil,
            destination: "operator/contracts",
            metadata: { reason: :file_parent, file_count: 1 }
          },
          {
            type: :copy_file,
            status: :planned,
            source: "files/operator/contracts/resolve_incident.rb",
            destination: "operator/contracts/resolve_incident.rb",
            metadata: {
              capsule: :operator,
              bytes: 11,
              intake_status: :planned,
              safe: true
            }
          },
          {
            type: :copy_file,
            status: :planned,
            source: "files/operator/igniter.rb",
            destination: "operator/igniter.rb",
            metadata: {
              capsule: :operator,
              bytes: 9,
              intake_status: :planned,
              safe: true
            }
          }
        ]
      )
      expect(File.exist?(File.join(destination, "operator/igniter.rb"))).to be(false)
    end
  end

  it "keeps intake blockers in transfer apply planning for serialized intake hashes" do
    Dir.mktmpdir("igniter-transfer-apply") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      destination = File.join(root, "destination")
      FileUtils.mkdir_p(File.join(destination, "operator/contracts"))
      File.write(File.join(destination, "operator/contracts/resolve_incident.rb"), "# existing\n")
      intake = Igniter::Application.transfer_intake_plan(artifact, destination_root: destination)
      serialized_intake = JSON.parse(JSON.generate(intake.to_h))

      apply_plan = Igniter::Application.transfer_apply_plan(serialized_intake).to_h

      expect(apply_plan).to include(
        executable: false,
        artifact_path: artifact,
        destination_root: destination,
        operation_count: 4,
        surface_count: 0
      )
      expect(apply_plan.fetch(:blockers).map { |entry| entry.fetch("code") }).to eq(["destination_conflict"])
      expect(apply_plan.fetch(:operations).map { |entry| entry.fetch(:status) }).to eq(
        %i[blocked blocked blocked blocked]
      )
      expect(File.read(File.join(destination, "operator/contracts/resolve_incident.rb"))).to eq("# existing\n")
    end
  end

  it "applies reviewed transfer plans in dry-run mode by default and commits explicitly" do
    Dir.mktmpdir("igniter-transfer-apply-execution") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      destination = File.join(root, "destination")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)

      dry_run = Igniter::Application.apply_transfer_plan(apply_plan, metadata: { source: :spec }).to_h

      expect(dry_run).to include(
        committed: false,
        executable: true,
        operation_count: 4,
        artifact_path: artifact,
        destination_root: destination,
        surface_count: 1,
        metadata: { source: :spec }
      )
      expect(dry_run.fetch(:applied).map { |entry| entry.fetch(:status) }).to eq(
        %i[dry_run dry_run dry_run dry_run]
      )
      expect(dry_run.fetch(:refusals)).to eq([])
      expect(File.exist?(File.join(destination, "operator/igniter.rb"))).to be(false)

      committed = Igniter::Application.apply_transfer_plan(apply_plan, commit: true).to_h

      expect(committed).to include(committed: true, executable: true, operation_count: 4)
      expect(committed.fetch(:applied).map { |entry| entry.fetch(:status) }).to eq(
        %i[applied applied applied applied]
      )
      expect(committed.fetch(:refusals)).to eq([])
      expect(File.read(File.join(destination, "operator/contracts/resolve_incident.rb"))).to eq("# contract\n")
      expect(File.read(File.join(destination, "operator/igniter.rb"))).to eq("# config\n")
    end
  end

  it "refuses committed transfer application when reviewed file destinations would overwrite" do
    Dir.mktmpdir("igniter-transfer-apply-execution") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      destination = File.join(root, "destination")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)
      FileUtils.mkdir_p(File.join(destination, "operator/contracts"))
      File.write(File.join(destination, "operator/contracts/resolve_incident.rb"), "# existing\n")

      result = Igniter::Application.apply_transfer_plan(apply_plan, commit: true).to_h

      expect(result).to include(committed: true, executable: true, operation_count: 4)
      expect(result.fetch(:applied)).to eq([])
      expect(result.fetch(:skipped).map { |entry| entry.fetch(:reason) }).to eq(
        %i[refusals_present refusals_present refusals_present refusals_present]
      )
      expect(result.fetch(:refusals)).to contain_exactly(
        include(code: :destination_exists)
      )
      expect(File.read(File.join(destination, "operator/contracts/resolve_incident.rb"))).to eq("# existing\n")
      expect(File.exist?(File.join(destination, "operator/igniter.rb"))).to be(false)
    end
  end

  it "keeps manual host wiring operations review-only during transfer apply execution" do
    Dir.mktmpdir("igniter-transfer-apply-execution") do |root|
      plan = {
        executable: true,
        artifact_path: root,
        destination_root: File.join(root, "destination"),
        operations: [
          {
            type: :manual_host_wiring,
            status: :review_required,
            source: :intake_required_host_wiring,
            destination: :host,
            metadata: { entry: { name: :incident_runtime } }
          }
        ],
        blockers: [],
        surface_count: 0
      }

      result = Igniter::Application.apply_transfer_plan(plan, commit: true).to_h

      expect(result).to include(committed: true, executable: true, operation_count: 1)
      expect(result.fetch(:applied)).to eq([])
      expect(result.fetch(:refusals)).to eq([])
      expect(result.fetch(:skipped)).to contain_exactly(
        include(
          type: :manual_host_wiring,
          status: :skipped,
          reason: :manual_host_wiring_review_only
        )
      )
    end
  end

  it "verifies committed transfer application results read-only" do
    Dir.mktmpdir("igniter-transfer-applied-verification") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      destination = File.join(root, "destination")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)
      apply_result = Igniter::Application.apply_transfer_plan(apply_plan, commit: true)

      report = Igniter::Application.verify_applied_transfer(
        apply_result,
        apply_plan: apply_plan,
        metadata: { source: :spec }
      ).to_h

      expect(report).to include(
        valid: true,
        committed: true,
        artifact_path: artifact,
        destination_root: destination,
        findings: [],
        refusals: [],
        skipped: [],
        operation_count: 4,
        surface_count: 1,
        metadata: { source: :spec }
      )
      expect(report.fetch(:verified)).to include(
        include(type: :ensure_directory, destination: "operator", status: :verified),
        include(type: :ensure_directory, destination: "operator/contracts", status: :verified),
        include(type: :copy_file, destination: "operator/contracts/resolve_incident.rb", bytes: 11),
        include(type: :copy_file, destination: "operator/igniter.rb", bytes: 9)
      )
    end
  end

  it "reports post-apply destination mismatches without repairing them" do
    Dir.mktmpdir("igniter-transfer-applied-verification") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      destination = File.join(root, "destination")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)
      apply_result = Igniter::Application.apply_transfer_plan(apply_plan, commit: true)
      File.write(File.join(destination, "operator/contracts/resolve_incident.rb"), "# changed!\n")

      report = Igniter::Application.verify_applied_transfer(
        JSON.parse(JSON.generate(apply_result.to_h)),
        apply_plan: JSON.parse(JSON.generate(apply_plan.to_h))
      ).to_h

      expect(report).to include(valid: false, committed: true, operation_count: 4)
      expect(report.fetch(:findings).map { |entry| entry.fetch(:code) }).to include(:content_mismatch)
      expect(report.fetch(:verified)).to include(
        include(type: :ensure_directory, destination: "operator"),
        include(type: :ensure_directory, destination: "operator/contracts"),
        include(type: :copy_file, destination: "operator/igniter.rb")
      )
      expect(File.read(File.join(destination, "operator/contracts/resolve_incident.rb"))).to eq("# changed!\n")
    end
  end

  it "marks dry-run transfer application results invalid during applied verification" do
    Dir.mktmpdir("igniter-transfer-applied-verification") do |root|
      apply_result = {
        committed: false,
        artifact_path: root,
        destination_root: File.join(root, "destination"),
        applied: [],
        skipped: [],
        refusals: [],
        operation_count: 0,
        surface_count: 0
      }

      report = Igniter::Application.verify_applied_transfer(apply_result).to_h

      expect(report).to include(valid: false, committed: false, verified: [], refusals: [], skipped: [])
      expect(report.fetch(:findings)).to contain_exactly(include(code: :not_committed))
    end
  end

  it "builds transfer receipts over explicit transfer reports" do
    Dir.mktmpdir("igniter-transfer-receipt") do |root|
      FileUtils.mkdir_p(File.join(root, "capsule/contracts"))
      FileUtils.mkdir_p(File.join(root, "capsule/spec"))
      FileUtils.mkdir_p(File.join(root, "capsule/web"))
      File.write(File.join(root, "capsule/contracts/resolve_incident.rb"), "# contract\n")
      File.write(File.join(root, "capsule/igniter.rb"), "# config\n")

      blueprint = Igniter::Application.blueprint(
        name: :operator,
        root: File.join(root, "capsule"),
        env: :test,
        layout_profile: :capsule,
        groups: [:contracts],
        web_surfaces: [:operator_console],
        imports: [
          { name: :incident_runtime, kind: :service, from: :host }
        ]
      )
      plan = Igniter::Application.transfer_bundle_plan(
        blueprint,
        subject: :operator_bundle,
        host_exports: [
          { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
        ],
        surface_metadata: [
          { name: :operator_console, kind: :web_surface, path: "web" }
        ]
      )
      artifact = File.join(root, "operator_bundle")
      destination = File.join(root, "destination")
      Igniter::Application.write_transfer_bundle(plan, output: artifact)
      verification = Igniter::Application.verify_transfer_bundle(artifact)
      intake = Igniter::Application.transfer_intake_plan(verification, destination_root: destination)
      apply_plan = Igniter::Application.transfer_apply_plan(intake)
      apply_result = Igniter::Application.apply_transfer_plan(apply_plan, commit: true)
      applied_verification = Igniter::Application.verify_applied_transfer(apply_result, apply_plan: apply_plan)

      receipt = Igniter::Application.transfer_receipt(
        applied_verification,
        apply_result: apply_result,
        apply_plan: apply_plan,
        metadata: { source: :spec }
      ).to_h

      expect(receipt).to include(
        complete: true,
        valid: true,
        committed: true,
        artifact_path: artifact,
        destination_root: destination,
        manual_actions: [],
        findings: [],
        refusals: [],
        skipped: [],
        surface_count: 1,
        metadata: { source: :spec }
      )
      expect(receipt.fetch(:counts)).to eq(
        planned: 4,
        applied: 4,
        verified: 4,
        findings: 0,
        refusals: 0,
        skipped: 0,
        manual_actions: 0
      )
    end
  end

  it "keeps transfer receipts compatible with serialized report hashes" do
    Dir.mktmpdir("igniter-transfer-receipt") do |root|
      applied_verification = {
        valid: false,
        committed: true,
        artifact_path: File.join(root, "artifact"),
        destination_root: File.join(root, "destination"),
        verified: [],
        findings: [
          { code: :content_mismatch, message: "changed" }
        ],
        refusals: [],
        skipped: [],
        operation_count: 1,
        surface_count: 0
      }
      apply_result = {
        applied: [
          { type: :copy_file, status: :applied, source: "files/operator/igniter.rb", destination: "operator/igniter.rb" }
        ]
      }
      apply_plan = {
        operation_count: 1,
        operations: [
          { type: :copy_file, source: "files/operator/igniter.rb", destination: "operator/igniter.rb" }
        ]
      }

      receipt = Igniter::Application.transfer_receipt(
        JSON.parse(JSON.generate(applied_verification)),
        apply_result: JSON.parse(JSON.generate(apply_result)),
        apply_plan: JSON.parse(JSON.generate(apply_plan))
      ).to_h

      expect(receipt).to include(complete: false, valid: false, committed: true)
      expect(receipt.fetch(:counts)).to include(
        planned: 1,
        applied: 1,
        verified: 0,
        findings: 1,
        refusals: 0,
        skipped: 0,
        manual_actions: 0
      )
      expect(receipt.fetch(:findings)).to contain_exactly(include("code" => "content_mismatch"))
    end
  end

  it "summarizes manual host wiring as transfer receipt manual actions" do
    Dir.mktmpdir("igniter-transfer-receipt") do |root|
      apply_plan = {
        operation_count: 1,
        operations: [
          {
            type: :manual_host_wiring,
            status: :review_required,
            source: :intake_required_host_wiring,
            destination: :host,
            metadata: { entry: { name: :incident_runtime } }
          }
        ]
      }
      apply_result = Igniter::Application.apply_transfer_plan(
        {
          executable: true,
          artifact_path: root,
          destination_root: File.join(root, "destination"),
          operations: apply_plan.fetch(:operations),
          blockers: [],
          surface_count: 0
        },
        commit: true
      )
      applied_verification = Igniter::Application.verify_applied_transfer(apply_result, apply_plan: apply_plan)

      receipt = Igniter::Application.transfer_receipt(
        applied_verification,
        apply_result: apply_result,
        apply_plan: apply_plan
      ).to_h

      expect(receipt).to include(valid: true, committed: true, complete: false)
      expect(receipt.fetch(:counts)).to include(
        planned: 1,
        applied: 0,
        verified: 0,
        skipped: 1,
        manual_actions: 1
      )
      expect(receipt.fetch(:manual_actions)).to contain_exactly(
        include(type: :manual_host_wiring, destination: :host)
      )
    end
  end

  it "reports host activation readiness over explicit host decisions" do
    receipt = {
      complete: true,
      valid: true,
      committed: true,
      manual_actions: [],
      surface_count: 1
    }
    handoff = {
      suggested_host_wiring: [
        {
          capsule: :operator,
          name: :incident_runtime,
          kind: :service,
          capabilities: [:audit]
        }
      ],
      mount_intents: [
        {
          capsule: :operator,
          kind: :web,
          at: "/operator",
          metadata: { surface: :operator_console }
        }
      ],
      surfaces: [
        { name: :operator_console, kind: :web_surface }
      ]
    }

    readiness = Igniter::Application.host_activation_readiness(
      receipt,
      handoff_manifest: handoff,
      host_exports: [
        { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
      ],
      host_capabilities: [:audit],
      load_paths: ["operator"],
      providers: [:incident_runtime],
      contracts: ["Contracts::ResolveIncident"],
      lifecycle: { boot: :manual_review },
      mount_decisions: [
        { capsule: :operator, kind: :web, at: "/operator", status: :accepted }
      ],
      metadata: { source: :spec }
    ).to_h

    expect(readiness).to include(
      ready: true,
      blockers: [],
      warnings: [],
      manual_actions: [],
      surface_count: 1,
      metadata: { source: :spec }
    )
    expect(readiness.fetch(:decisions)).to include(
      host_capabilities: [:audit],
      load_paths: ["operator"],
      providers: [:incident_runtime],
      contracts: ["Contracts::ResolveIncident"],
      lifecycle: { boot: :manual_review }
    )
    expect(readiness.fetch(:mount_intents)).to contain_exactly(
      include(capsule: :operator, kind: :web, at: "/operator")
    )
  end

  it "blocks host activation readiness for incomplete receipts and unresolved host decisions" do
    receipt = {
      complete: false,
      valid: true,
      committed: true,
      manual_actions: [
        {
          type: :manual_host_wiring,
          status: :skipped,
          metadata: { entry: { name: :incident_runtime } }
        }
      ],
      surface_count: 0
    }
    handoff = {
      suggested_host_wiring: [
        {
          capsule: :operator,
          name: :incident_runtime,
          kind: :service,
          capabilities: [:audit]
        }
      ],
      mount_intents: []
    }

    readiness = Igniter::Application.host_activation_readiness(
      JSON.parse(JSON.generate(receipt)),
      handoff_manifest: JSON.parse(JSON.generate(handoff)),
      lifecycle: { boot: :manual_review }
    ).to_h

    expect(readiness).to include(ready: false)
    expect(readiness.fetch(:blockers).map { |entry| entry.fetch(:code) }).to include(
      :transfer_receipt_incomplete,
      :missing_host_export,
      :missing_host_capability,
      :manual_action_unresolved
    )
    expect(readiness.fetch(:warnings).map { |entry| entry.fetch(:code) }).to include(
      :load_paths_unconfirmed,
      :providers_unconfirmed,
      :contracts_unconfirmed
    )
  end

  it "plans host activation review operations over accepted readiness" do
    readiness = Igniter::Application.host_activation_readiness(
      {
        complete: true,
        valid: true,
        committed: true,
        manual_actions: [],
        surface_count: 1
      },
      handoff_manifest: {
        suggested_host_wiring: [
          {
            capsule: :operator,
            name: :incident_runtime,
            kind: :service,
            capabilities: [:audit]
          }
        ],
        mount_intents: [
          {
            capsule: :operator,
            kind: :web,
            at: "/operator",
            metadata: { surface: :operator_console }
          }
        ]
      },
      host_exports: [
        { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
      ],
      host_capabilities: [:audit],
      load_paths: ["operator"],
      providers: [:incident_runtime],
      contracts: ["Contracts::ResolveIncident"],
      lifecycle: { boot: :manual_review },
      mount_decisions: [
        { capsule: :operator, kind: :web, at: "/operator", status: :accepted }
      ]
    )

    plan = Igniter::Application.host_activation_plan(readiness, metadata: { source: :spec }).to_h

    expect(plan).to include(
      executable: true,
      blockers: [],
      warnings: [],
      surface_count: 1,
      metadata: { source: :spec }
    )
    expect(plan.fetch(:operations).map { |entry| entry.fetch(:type) }).to eq(
      %i[
        confirm_host_export
        confirm_host_capability
        confirm_load_path
        confirm_provider
        confirm_contract
        confirm_lifecycle
        review_mount_intent
      ]
    )
    expect(plan.fetch(:operations)).to include(
      include(type: :confirm_load_path, status: :review_required, destination: "operator"),
      include(type: :confirm_contract, status: :review_required, destination: "Contracts::ResolveIncident"),
      include(type: :review_mount_intent, status: :review_required, destination: "/operator")
    )
  end

  it "refuses host activation plans when readiness is not accepted" do
    readiness = {
      ready: false,
      blockers: [
        { code: :missing_host_export, message: "Required host export decision is missing." }
      ],
      warnings: [
        { code: :load_paths_unconfirmed, message: "Host load path decision was not supplied." }
      ],
      decisions: {
        load_paths: ["operator"]
      },
      manual_actions: [],
      mount_intents: [],
      surface_count: 0
    }

    plan = Igniter::Application.host_activation_plan(JSON.parse(JSON.generate(readiness))).to_h

    expect(plan).to include(
      executable: false,
      operations: [],
      surface_count: 0
    )
    expect(plan.fetch(:blockers)).to contain_exactly(include(code: "missing_host_export"))
    expect(plan.fetch(:warnings)).to contain_exactly(include(code: "load_paths_unconfirmed"))
  end

  it "verifies host activation plans as descriptive review data" do
    readiness = Igniter::Application.host_activation_readiness(
      {
        complete: true,
        valid: true,
        committed: true,
        manual_actions: [],
        surface_count: 1
      },
      handoff_manifest: {
        suggested_host_wiring: [
          { capsule: :operator, name: :incident_runtime, kind: :service, capabilities: [:audit] }
        ],
        mount_intents: [
          { capsule: :operator, kind: :web, at: "/operator", metadata: { surface: :operator_console } }
        ]
      },
      host_exports: [
        { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
      ],
      host_capabilities: [:audit],
      load_paths: ["operator"],
      providers: [:incident_runtime],
      contracts: ["Contracts::ResolveIncident"],
      lifecycle: { boot: :manual_review },
      mount_decisions: [
        { capsule: :operator, kind: :web, at: "/operator", status: :accepted }
      ]
    )
    plan = Igniter::Application.host_activation_plan(readiness)

    verification = Igniter::Application.verify_host_activation_plan(plan, metadata: { source: :spec }).to_h

    expect(verification).to include(
      valid: true,
      executable: true,
      findings: [],
      operation_count: 7,
      surface_count: 1,
      metadata: { source: :spec }
    )
    expect(verification.fetch(:verified).map { |entry| entry.fetch(:type) }).to include(
      :confirm_load_path,
      :confirm_provider,
      :confirm_contract,
      :confirm_lifecycle,
      :review_mount_intent
    )
  end

  it "flags activation plan verification findings for non-review operations" do
    plan = {
      executable: true,
      operations: [
        {
          type: :activate_route,
          status: :executed,
          source: :runtime,
          destination: "/operator",
          metadata: { route: "/operator" }
        },
        {
          type: :review_mount_intent,
          status: :review_required,
          source: :activation_readiness_mount_intent,
          destination: "/operator",
          metadata: {}
        }
      ],
      blockers: [],
      warnings: [],
      surface_count: 1
    }

    verification = Igniter::Application.verify_host_activation_plan(JSON.parse(JSON.generate(plan))).to_h

    expect(verification).to include(valid: false, executable: true, verified: [], operation_count: 2)
    expect(verification.fetch(:findings).map { |entry| entry.fetch(:code) }).to include(
      :unknown_operation_type,
      :operation_not_review_required,
      :mount_intent_metadata_missing
    )
  end

  it "accepts blocked host activation plans when blockers explain the refusal" do
    plan = {
      executable: false,
      operations: [],
      blockers: [
        { code: :missing_host_export, message: "Required host export decision is missing." }
      ],
      warnings: [],
      surface_count: 0
    }

    verification = Igniter::Application.verify_host_activation_plan(plan).to_h

    expect(verification).to include(
      valid: true,
      executable: false,
      verified: [],
      findings: [],
      operation_count: 0,
      surface_count: 0
    )
  end

  it "reports dry-run host activation over verified plan data" do
    readiness = Igniter::Application.host_activation_readiness(
      {
        complete: true,
        valid: true,
        committed: true,
        manual_actions: [],
        surface_count: 1
      },
      handoff_manifest: {
        suggested_host_wiring: [
          { capsule: :operator, name: :incident_runtime, kind: :service, capabilities: [:audit] }
        ],
        mount_intents: [
          { capsule: :operator, kind: :web, at: "/operator", metadata: { surface: :operator_console } }
        ]
      },
      host_exports: [
        { name: :incident_runtime, kind: :service, target: "Host::IncidentRuntime" }
      ],
      host_capabilities: [:audit],
      load_paths: ["operator"],
      providers: [:incident_runtime],
      contracts: ["Contracts::ResolveIncident"],
      lifecycle: { boot: :manual_review },
      mount_decisions: [
        { capsule: :operator, kind: :web, at: "/operator", status: :accepted }
      ]
    )
    plan = Igniter::Application.host_activation_plan(readiness)
    verification = Igniter::Application.verify_host_activation_plan(plan)

    report = Igniter::Application.dry_run_host_activation(
      verification,
      host_target: "Host::OperatorRuntime",
      metadata: { source: :spec }
    ).to_h

    expect(report).to include(
      dry_run: true,
      committed: false,
      executable: true,
      refusals: [],
      warnings: [],
      surface_count: 1,
      metadata: { source: :spec }
    )
    expect(report.fetch(:would_apply).map { |entry| entry.fetch(:type) }).to eq(
      %i[confirm_load_path confirm_provider confirm_contract confirm_lifecycle]
    )
    expect(report.fetch(:would_apply)).to all(include(status: :dry_run, target: "Host::OperatorRuntime"))
    expect(report.fetch(:skipped).map { |entry| entry.fetch(:reason) }).to include(
      :host_owned_evidence,
      :web_or_host_owned_mount
    )
  end

  it "refuses dry-run host activation without verified executable input and host target" do
    verification = {
      valid: false,
      executable: true,
      verified: [
        {
          type: :confirm_provider,
          status: :review_required,
          source: :activation_readiness_provider,
          destination: :incident_runtime,
          metadata: { provider: :incident_runtime }
        }
      ],
      findings: [
        { code: :operation_not_review_required, message: "bad" }
      ],
      surface_count: 0
    }

    report = Igniter::Application.dry_run_host_activation(JSON.parse(JSON.generate(verification))).to_h

    expect(report).to include(
      dry_run: true,
      committed: false,
      executable: false,
      would_apply: [],
      surface_count: 0
    )
    expect(report.fetch(:refusals).map { |entry| entry.fetch(:code) }).to include(
      :verification_invalid,
      :missing_host_target
    )
    expect(report.fetch(:skipped)).to contain_exactly(
      include(type: :confirm_provider, status: :skipped, reason: :missing_host_target)
    )
  end

  it "reports host activation commit readiness over explicit adapter evidence" do
    dry_run = {
      dry_run: true,
      committed: false,
      executable: true,
      would_apply: [
        { type: :confirm_load_path, status: :dry_run, destination: "operator" },
        { type: :confirm_provider, status: :dry_run, destination: :incident_runtime }
      ],
      skipped: [
        { type: :confirm_host_export, status: :skipped, reason: :host_owned_evidence },
        { type: :review_mount_intent, status: :skipped, reason: :web_or_host_owned_mount }
      ],
      refusals: [],
      warnings: [],
      surface_count: 1
    }

    readiness = Igniter::Application.host_activation_commit_readiness(
      dry_run,
      provided_adapters: [
        { name: :application_host_target, kind: :application_host_adapter, target: "Host::OperatorRuntime" },
        { name: :host_evidence_acknowledgement, kind: :host_evidence },
        { name: :web_mount_adapter_evidence, kind: :web_or_host_mount_evidence }
      ],
      metadata: { source: :spec }
    ).to_h

    expect(readiness).to include(
      ready: true,
      commit_allowed: true,
      dry_run: true,
      committed: false,
      blockers: [],
      warnings: [],
      would_apply_count: 2,
      skipped_count: 2,
      metadata: { source: :spec }
    )
    expect(readiness.fetch(:required_adapters).map { |entry| entry.fetch(:name) }).to contain_exactly(
      :application_host_target,
      :host_evidence_acknowledgement,
      :web_mount_adapter_evidence
    )
  end

  it "blocks host activation commit readiness when dry-run evidence or adapters are missing" do
    dry_run = {
      dry_run: true,
      committed: false,
      executable: true,
      would_apply: [
        { type: :confirm_provider, status: :dry_run, destination: :incident_runtime }
      ],
      skipped: [
        { type: :review_mount_intent, status: :skipped, reason: :web_or_host_owned_mount }
      ],
      refusals: [
        { code: :missing_host_target, message: "missing" }
      ],
      warnings: [
        { code: :dry_run_note, message: "note" }
      ],
      surface_count: 1
    }

    readiness = Igniter::Application.host_activation_commit_readiness(
      JSON.parse(JSON.generate(dry_run)),
      provided_adapters: [{ name: :application_host_target }]
    ).to_h

    expect(readiness).to include(
      ready: false,
      commit_allowed: false,
      dry_run: true,
      committed: false,
      would_apply_count: 1,
      skipped_count: 1
    )
    expect(readiness.fetch(:blockers).map { |entry| entry.fetch(:code) }).to include(
      :dry_run_refusal,
      :missing_adapter_evidence
    )
    expect(readiness.fetch(:warnings)).to contain_exactly(include(code: :dry_run_warning))
    expect(readiness.fetch(:required_adapters).map { |entry| entry.fetch(:name) }).to include(
      :application_host_target,
      :web_mount_adapter_evidence
    )
  end

  it "commits host activation confirmations to an explicit file-backed ledger adapter" do
    Dir.mktmpdir("igniter-host-activation-ledger") do |root|
      dry_run = {
        dry_run: true,
        committed: false,
        executable: true,
        would_apply: [
          { type: :confirm_load_path, status: :dry_run, destination: "operator" },
          { type: :confirm_provider, status: :dry_run, destination: :incident_runtime }
        ],
        skipped: [
          { type: :confirm_host_export, status: :skipped, reason: :host_owned_evidence },
          { type: :review_mount_intent, status: :skipped, reason: :web_or_host_owned_mount }
        ],
        refusals: [],
        warnings: [],
        surface_count: 1
      }
      readiness = Igniter::Application.host_activation_commit_readiness(
        dry_run,
        provided_adapters: [
          { name: :application_host_target, kind: :application_host_adapter, target: "Host::OperatorRuntime" },
          { name: :host_evidence_acknowledgement, kind: :host_evidence },
          { name: :web_mount_adapter_evidence, kind: :web_or_host_mount_evidence }
        ]
      ).to_h
      digest = Igniter::Application.host_activation_operation_digest(dry_run)
      adapter = Igniter::Application.file_backed_host_activation_ledger_adapter(root: root)

      result = Igniter::Application.host_activation_ledger_commit(
        activation_evidence_packet(dry_run: dry_run, readiness: readiness, digest: digest),
        adapter: adapter,
        metadata: { source: :spec }
      ).to_h

      expect(result).to include(
        committed: true,
        dry_run: false,
        operation_digest: digest,
        refusals: [],
        metadata: { source: :spec }
      )
      expect(result.fetch(:applied_operations).map { |entry| entry.fetch(:type) }).to contain_exactly(
        :confirm_load_path,
        :confirm_provider
      )
      expect(result.fetch(:skipped_operations).map { |entry| entry.fetch(:reason) }).to include(
        :host_owned_evidence,
        :web_or_host_owned_mount
      )
      expect(adapter.readback(idempotency_key: "activation-key-1", operation_digest: digest).length).to eq(2)
    end
  end

  it "reuses matching activation ledger idempotency keys and refuses mismatched digests" do
    Dir.mktmpdir("igniter-host-activation-ledger") do |root|
      dry_run = {
        dry_run: true,
        committed: false,
        executable: true,
        would_apply: [
          { type: :confirm_contract, status: :dry_run, destination: "Contracts::ResolveIncident" }
        ],
        skipped: [],
        refusals: [],
        warnings: [],
        surface_count: 0
      }
      readiness = Igniter::Application.host_activation_commit_readiness(
        dry_run,
        provided_adapters: [
          { name: :application_host_target, kind: :application_host_adapter, target: "Host::OperatorRuntime" }
        ]
      ).to_h
      digest = Igniter::Application.host_activation_operation_digest(dry_run)
      adapter = Igniter::Application.file_backed_host_activation_ledger_adapter(root: root)
      packet = activation_evidence_packet(dry_run: dry_run, readiness: readiness, digest: digest)

      first = Igniter::Application.host_activation_ledger_commit(packet, adapter: adapter).to_h
      duplicate = Igniter::Application.host_activation_ledger_commit(packet, adapter: adapter).to_h
      changed_dry_run = dry_run.merge(
        would_apply: [
          { type: :confirm_contract, status: :dry_run, destination: "Contracts::ReassignIncident" }
        ]
      )
      changed_digest = Igniter::Application.host_activation_operation_digest(changed_dry_run)
      mismatch = Igniter::Application.host_activation_ledger_commit(
        activation_evidence_packet(dry_run: changed_dry_run, readiness: readiness, digest: changed_digest),
        adapter: adapter
      ).to_h

      expect(first.fetch(:committed)).to be(true)
      expect(duplicate.fetch(:committed)).to be(true)
      expect(duplicate.fetch(:adapter_receipts).first.fetch(:idempotency_key)).to eq("activation-key-1")
      expect(adapter.readback(idempotency_key: "activation-key-1").length).to eq(1)
      expect(mismatch.fetch(:committed)).to be(false)
      expect(mismatch.fetch(:refusals).map { |entry| entry.fetch(:code) }).to include(:idempotency_key_reused)
    end
  end

  it "refuses host activation ledger commits before adapter calls when evidence is invalid" do
    Dir.mktmpdir("igniter-host-activation-ledger") do |root|
      dry_run = {
        dry_run: true,
        committed: false,
        executable: true,
        would_apply: [
          { type: :review_mount_intent, status: :dry_run, destination: "/operator" }
        ],
        skipped: [],
        refusals: [],
        warnings: [],
        surface_count: 1
      }
      readiness = { blockers: [{ code: :missing_adapter_evidence }] }
      adapter = Igniter::Application.file_backed_host_activation_ledger_adapter(root: root)
      packet = activation_evidence_packet(
        dry_run: dry_run.merge(activation_dry_run_id: "stale-dry-run"),
        readiness: readiness,
        digest: Igniter::Application.host_activation_operation_digest(dry_run)
      ).merge(commit_decision: false, host_target: "Host::ImplicitDiscovery")

      result = Igniter::Application.host_activation_ledger_commit(packet, adapter: adapter).to_h

      expect(result).to include(committed: false, applied_operations: [], adapter_receipts: [])
      expect(result.fetch(:refusals).map { |entry| entry.fetch(:code) }).to include(
        :commit_not_explicit,
        :commit_readiness_blocker,
        :forbidden_evidence_field,
        :stale_evidence_identity,
        :unsupported_operation_type
      )
      expect(Dir.glob(File.join(root, "activation-ledger", "*.json"))).to be_empty
    end
  end

  it "verifies host activation ledger readback and produces a separate activation receipt" do
    Dir.mktmpdir("igniter-host-activation-ledger") do |root|
      dry_run = {
        dry_run: true,
        committed: false,
        executable: true,
        would_apply: [
          { type: :confirm_load_path, status: :dry_run, destination: "operator" },
          { type: :confirm_lifecycle, status: :dry_run, destination: :boot }
        ],
        skipped: [
          { type: :confirm_host_export, status: :skipped, reason: :host_owned_evidence },
          { type: :review_mount_intent, status: :skipped, reason: :web_or_host_owned_mount }
        ],
        refusals: [],
        warnings: [],
        surface_count: 1
      }
      digest = Igniter::Application.host_activation_operation_digest(dry_run)
      adapter = Igniter::Application.file_backed_host_activation_ledger_adapter(root: root)
      readiness = Igniter::Application.host_activation_commit_readiness(
        dry_run,
        provided_adapters: [
          adapter.to_h,
          { name: :host_evidence_acknowledgement, kind: :host_evidence },
          { name: :web_mount_adapter_evidence, kind: :web_or_host_mount_evidence }
        ]
      ).to_h
      packet = activation_evidence_packet(dry_run: dry_run, readiness: readiness, digest: digest)
      commit = Igniter::Application.host_activation_ledger_commit(packet, adapter: adapter).to_h

      verification = Igniter::Application.verify_host_activation_ledger(
        packet,
        commit_result: commit,
        adapter: adapter,
        metadata: { source: :spec }
      ).to_h
      receipt = Igniter::Application.host_activation_receipt(
        verification,
        evidence_packet: packet,
        commit_result: commit,
        metadata: { reviewer: :application_spec }
      ).to_h

      expect(verification).to include(
        valid: true,
        complete: true,
        committed: true,
        packet_id: "activation-packet-1",
        result_id: "activation-ledger-result:activation-packet-1",
        operation_digest: digest,
        idempotency_key: "activation-key-1",
        findings: [],
        unexpected_operations: [],
        metadata: { source: :spec }
      )
      expect(verification.fetch(:counts)).to include(expected: 2, readback: 2, verified: 2, skipped: 2)
      expect(receipt).to include(
        schema_version: "activation-receipt-v1",
        transfer_receipt_id: "transfer-receipt-1",
        packet_id: "activation-packet-1",
        result_id: "activation-ledger-result:activation-packet-1",
        valid: true,
        complete: true,
        committed: true,
        operation_digest: digest
      )
      expect(receipt.fetch(:host_leftovers).length).to eq(1)
      expect(receipt.fetch(:web_leftovers).length).to eq(1)
      expect(receipt.fetch(:adapter_receipt_refs).length).to eq(2)
      expect(receipt.fetch(:audit_metadata)).to include(separate_from_transfer_receipt: true)
    end
  end

  it "reports missing unexpected mismatched and duplicate ledger readback records" do
    Dir.mktmpdir("igniter-host-activation-ledger") do |root|
      dry_run = {
        dry_run: true,
        committed: false,
        executable: true,
        would_apply: [
          { type: :confirm_provider, status: :dry_run, destination: :incident_runtime },
          { type: :confirm_contract, status: :dry_run, destination: "Contracts::ResolveIncident" }
        ],
        skipped: [],
        refusals: [],
        warnings: [],
        surface_count: 0
      }
      digest = Igniter::Application.host_activation_operation_digest(dry_run)
      adapter = Igniter::Application.file_backed_host_activation_ledger_adapter(root: root)
      readiness = Igniter::Application.host_activation_commit_readiness(
        dry_run,
        provided_adapters: [adapter.to_h]
      ).to_h
      packet = activation_evidence_packet(dry_run: dry_run, readiness: readiness, digest: digest)
      commit = Igniter::Application.host_activation_ledger_commit(packet, adapter: adapter).to_h
      first_receipt = commit.fetch(:adapter_receipts).first
      duplicate = first_receipt.merge(receipt_id: "activation-ledger:duplicate")
      unexpected = first_receipt.merge(
        receipt_id: "activation-ledger:unexpected",
        packet_id: "other-packet",
        operation_digest: "other-digest",
        idempotency_key: "other-key",
        operation: first_receipt.fetch(:operation).merge(
          operation_key: "confirm_lifecycle:shutdown:",
          type: :confirm_lifecycle,
          destination: :shutdown
        )
      )
      verifier_adapter = ActivationLedgerReadbackProbe.new([first_receipt, duplicate, unexpected])

      verification = Igniter::Application.verify_host_activation_ledger(
        packet,
        commit_result: commit,
        adapter: verifier_adapter
      ).to_h
      receipt = Igniter::Application.host_activation_receipt(
        verification,
        evidence_packet: packet,
        commit_result: commit
      ).to_h

      expect(verification).to include(valid: false, complete: false)
      expect(verification.fetch(:findings).map { |entry| entry.fetch(:code) }).to include(
        :missing_ledger_record,
        :unexpected_ledger_record,
        :duplicate_ledger_record,
        :packet_id_mismatch,
        :operation_digest_mismatch,
        :idempotency_key_mismatch,
        :commit_receipt_missing_from_readback
      )
      expect(receipt).to include(valid: false, complete: false, committed: true)
    end
  end

  it "refuses committed transfer application without explicit apply roots" do
    plan = {
      executable: true,
      artifact_path: "",
      destination_root: "",
      operations: [
        {
          type: :copy_file,
          status: :planned,
          source: "Gemfile",
          destination: "tmp/unsafe-copy",
          metadata: { safe: true }
        }
      ],
      blockers: [],
      surface_count: 0
    }

    result = Igniter::Application.apply_transfer_plan(plan, commit: true).to_h

    expect(result).to include(committed: true, executable: true, applied: [])
    expect(result.fetch(:skipped)).to contain_exactly(
      include(type: :copy_file, status: :skipped, reason: :refusals_present)
    )
    expect(result.fetch(:refusals).map { |entry| entry.fetch(:code) }).to include(
      :missing_artifact_root,
      :missing_destination_root
    )
  end

  it "supports named layout profiles and active groups for app capsules" do
    root = File.expand_path("/tmp/igniter_operator_capsule")
    blueprint = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      web_surfaces: [:operator_console]
    )

    expect(blueprint.to_h).to include(
      layout_profile: :capsule,
      groups: %i[contracts services],
      active_groups: %i[config contracts services spec web]
    )
    expect(blueprint.layout.path(:contracts)).to eq("contracts")
    expect(blueprint.layout.path(:config)).to eq("igniter.rb")
    expect(blueprint.layout.path(:web)).to eq("web")

    sparse_plan = blueprint.structure_plan
    complete_plan = blueprint.structure_plan(mode: :complete)

    expect(sparse_plan.to_h).to include(
      mode: :sparse,
      layout_profile: :capsule,
      missing_groups: %i[config contracts services spec web]
    )
    expect(complete_plan.to_h).to include(
      mode: :complete,
      missing_groups: %i[agents config contracts effects executors packs providers services skills spec support tools web]
    )
  end

  it "publishes capsule exports and imports as manifest portability metadata" do
    root = File.expand_path("/tmp/igniter_operator_capsule_manifest")
    blueprint = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      exports: [
        { name: :cluster_status, as: :service, target: "Services::ClusterStatus" },
        { name: :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident" }
      ],
      imports: [
        { name: :incident_runtime, kind: :service, from: :host, capabilities: [:incidents] },
        { name: :audit_log, kind: :service, from: :observability, optional: true }
      ]
    )

    expect(blueprint.to_h).to include(
      exports: [
        { name: :cluster_status, kind: :service, target: "Services::ClusterStatus", metadata: {} },
        { name: :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident", metadata: {} }
      ],
      imports: [
        {
          name: :incident_runtime,
          kind: :service,
          from: :host,
          optional: false,
          capabilities: [:incidents],
          metadata: {}
        },
        {
          name: :audit_log,
          kind: :service,
          from: :observability,
          optional: true,
          capabilities: [],
          metadata: {}
        }
      ]
    )

    manifest = blueprint.to_manifest
    expect(manifest.exports).to eq(blueprint.exports.map(&:to_h))
    expect(manifest.imports).to eq(blueprint.imports.map(&:to_h))
    expect(manifest.metadata).to include(
      layout_profile: :capsule,
      exports: blueprint.exports.map(&:to_h),
      imports: blueprint.imports.map(&:to_h)
    )

    profile = blueprint.apply_to(Igniter::Application.build_kernel).finalize
    expect(profile.manifest.exports).to eq(blueprint.exports.map(&:to_h))
    expect(profile.manifest.imports).to eq(blueprint.imports.map(&:to_h))
  end

  it "reports optional feature slices from blueprints without requiring features directories" do
    root = File.expand_path("/tmp/igniter_feature_slice_report")
    sparse_blueprint = Igniter::Application.blueprint(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule
    )
    blueprint = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      web_surfaces: [:operator_console],
      exports: [
        { name: :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident" }
      ],
      imports: [
        { name: :incident_runtime, kind: :service, from: :host, capabilities: [:incidents] }
      ],
      features: [
        {
          name: :incidents,
          groups: %i[contracts services web],
          paths: {
            contracts: "features/incidents/contracts",
            web: "features/incidents/web"
          },
          contracts: ["Contracts::ResolveIncident"],
          services: [:incident_queue],
          exports: [:resolve_incident],
          imports: [:incident_runtime],
          flows: [:incident_review],
          surfaces: [:operator_console],
          metadata: { owner: :operations }
        }
      ]
    )

    expect(sparse_blueprint.feature_slice_report.to_h).to include(
      application_name: :worker,
      slice_count: 0,
      slices: []
    )

    report = blueprint.feature_slice_report(metadata: { source: :spec })
    expect(report.to_h).to include(
      application_name: :operator,
      layout_profile: :capsule,
      slice_count: 1,
      metadata: { source: :spec }
    )
    expect(report.to_h.fetch(:slices)).to contain_exactly(
      include(
        name: :incidents,
        groups: %i[contracts services web],
        paths: {
          contracts: "features/incidents/contracts",
          web: "features/incidents/web"
        },
        contracts: ["Contracts::ResolveIncident"],
        services: [:incident_queue],
        exports: [:resolve_incident],
        imports: [:incident_runtime],
        flows: [:incident_review],
        surfaces: [:operator_console]
      )
    )
    expect(blueprint.to_manifest.feature_slices).to eq(blueprint.feature_slices.map(&:to_h))
  end

  it "publishes app-owned flow declaration metadata without starting a flow implicitly" do
    root = File.expand_path("/tmp/igniter_flow_declaration")
    blueprint = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      contracts: ["Contracts::ResolveIncident"],
      services: [:incident_queue],
      web_surfaces: [:operator_console],
      flows: [
        {
          name: :incident_review,
          purpose: "Review incident plan before execution",
          initial_status: :waiting_for_user,
          current_step: :review_plan,
          pending_inputs: [
            { name: :clarification, input_type: :textarea, target: :review_plan }
          ],
          pending_actions: [
            { name: :approve_plan, action_type: :contract, target: "Contracts::ResolveIncident" }
          ],
          artifacts: [
            { name: :draft_plan, artifact_type: :markdown, uri: "memory://draft-plan" }
          ],
          contracts: ["Contracts::ResolveIncident"],
          services: [:incident_queue],
          surfaces: [:operator_console],
          exports: [:resolve_incident],
          imports: [:incident_runtime],
          metadata: { feature: :incidents }
        }
      ]
    )
    declaration = blueprint.flow_declarations.first
    environment = described_class.new(profile: blueprint.apply_to(Igniter::Application.build_kernel).finalize)

    expect(declaration.to_h).to include(
      name: :incident_review,
      initial_status: :waiting_for_user,
      current_step: :review_plan,
      pending_inputs: [include(name: :clarification)],
      pending_actions: [include(name: :approve_plan)],
      contracts: ["Contracts::ResolveIncident"],
      services: [:incident_queue],
      surfaces: [:operator_console]
    )
    expect(environment.sessions).to eq([])

    snapshot = environment.start_flow(
      declaration.name,
      session_id: "incident-review/1",
      status: declaration.initial_status,
      current_step: declaration.current_step,
      pending_inputs: declaration.pending_inputs.map(&:to_h),
      pending_actions: declaration.pending_actions.map(&:to_h),
      artifacts: declaration.artifacts.map(&:to_h),
      metadata: { declaration: declaration.name }
    )

    expect(snapshot.status).to eq(:waiting_for_user)
    expect(snapshot.pending_inputs.map(&:name)).to eq([:clarification])
    expect(environment.manifest.flow_declarations).to eq(blueprint.flow_declarations.map(&:to_h))
  end

  it "builds capsule inspection reports for sparse non-web blueprints" do
    root = File.expand_path("/tmp/igniter_capsule_report_worker")
    blueprint = Igniter::Application.blueprint(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule,
      services: [:worker_queue]
    )

    report = blueprint.capsule_report(metadata: { source: :spec }).to_h

    expect(report).to include(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule,
      exports: [],
      imports: [],
      feature_slices: [],
      flow_declarations: [],
      services: [:worker_queue],
      web_surfaces: [],
      surfaces: [],
      metadata: { source: :spec }
    )
    expect(report.fetch(:groups)).to include(
      active: %i[config services spec],
      known: %i[agents config contracts effects executors packs providers services skills spec support tools web]
    )
    expect(report.fetch(:planned_paths).fetch(:sparse).map { |entry| entry.fetch(:group) }).to eq(
      %i[config services spec]
    )
  end

  it "builds capsule inspection reports with feature, flow, and supplied surface metadata" do
    root = File.expand_path("/tmp/igniter_capsule_report_operator")
    blueprint = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      contracts: ["Contracts::ResolveIncident"],
      services: [:incident_queue],
      web_surfaces: [:operator_console],
      exports: [
        { name: :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident" }
      ],
      imports: [
        { name: :incident_runtime, kind: :service, from: :host, capabilities: [:incidents] }
      ],
      features: [
        {
          name: :incidents,
          groups: %i[contracts services web],
          contracts: ["Contracts::ResolveIncident"],
          services: [:incident_queue],
          flows: [:incident_review],
          surfaces: [:operator_console]
        }
      ],
      flows: [
        {
          name: :incident_review,
          purpose: "Review incident plan",
          initial_status: :waiting_for_user,
          pending_inputs: [
            { name: :clarification, input_type: :textarea, target: :review_plan }
          ],
          pending_actions: [
            { name: :approve_plan, action_type: :contract, target: "Contracts::ResolveIncident" }
          ],
          surfaces: [:operator_console]
        }
      ]
    )
    surface_projection = {
      name: :operator_console,
      kind: :web_surface_projection,
      status: :aligned,
      metadata: { source: :spec }
    }

    report = blueprint.capsule_report(surface_metadata: [surface_projection]).to_h

    expect(report.fetch(:exports).map { |entry| entry.fetch(:name) }).to eq([:resolve_incident])
    expect(report.fetch(:imports).map { |entry| entry.fetch(:name) }).to eq([:incident_runtime])
    expect(report.fetch(:feature_slices).map { |entry| entry.fetch(:name) }).to eq([:incidents])
    expect(report.fetch(:flow_declarations).map { |entry| entry.fetch(:name) }).to eq([:incident_review])
    expect(report.fetch(:surfaces)).to eq([surface_projection])
    expect(report.fetch(:planned_paths).fetch(:complete).map { |entry| entry.fetch(:group) }).to include(
      :contracts,
      :services,
      :web
    )
  end

  it "builds equivalent application blueprints through the capsule authoring DSL" do
    root = File.expand_path("/tmp/igniter_capsule_authoring_dsl")
    clean = Igniter::Application.blueprint(
      name: :operator,
      root: root,
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      contracts: ["Contracts::ResolveIncident"],
      services: [:incident_queue],
      web_surfaces: [:operator_console],
      exports: [
        { name: :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident" }
      ],
      imports: [
        { name: :incident_runtime, kind: :service, from: :host, capabilities: [:incidents] }
      ],
      features: [
        {
          name: :incidents,
          groups: %i[contracts services web],
          contracts: ["Contracts::ResolveIncident"],
          services: [:incident_queue],
          exports: [:resolve_incident],
          imports: [:incident_runtime],
          flows: [:incident_review],
          surfaces: [:operator_console]
        }
      ],
      flows: [
        {
          name: :incident_review,
          purpose: "Review incident plan before execution",
          initial_status: :waiting_for_user,
          current_step: :review_plan,
          pending_inputs: [
            { name: :clarification, input_type: :textarea, target: :review_plan }
          ],
          pending_actions: [
            { name: :approve_plan, action_type: :contract, target: "Contracts::ResolveIncident" }
          ],
          contracts: ["Contracts::ResolveIncident"],
          services: [:incident_queue],
          surfaces: [:operator_console]
        }
      ]
    )
    capsule = Igniter::Application.capsule(:operator, root: root, env: :test) do
      layout :capsule
      groups :contracts, :services
      contract "Contracts::ResolveIncident"
      service :incident_queue
      web_surface :operator_console
      export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
      import :incident_runtime, kind: :service, from: :host, capabilities: [:incidents]

      feature :incidents do
        groups :contracts, :services, :web
        contract "Contracts::ResolveIncident"
        service :incident_queue
        export :resolve_incident
        import :incident_runtime
        flow :incident_review
        surface :operator_console
      end

      flow :incident_review do
        purpose "Review incident plan before execution"
        initial_status :waiting_for_user
        current_step :review_plan
        pending_input :clarification, input_type: :textarea, target: :review_plan
        pending_action :approve_plan, action_type: :contract, target: "Contracts::ResolveIncident"
        contract "Contracts::ResolveIncident"
        service :incident_queue
        surface :operator_console
      end
    end

    expect(capsule.to_blueprint.to_h).to eq(clean.to_h)
    expect(capsule.to_h).to include(
      kind: :application_capsule,
      name: :operator,
      layout_profile: :capsule,
      blueprint: clean.to_h
    )
  end

  it "reports capsule composition readiness without loading or executing capsules" do
    root = File.expand_path("/tmp/igniter_capsule_composition")
    provider = Igniter::Application.blueprint(
      name: :incident_core,
      root: File.join(root, "incident_core"),
      env: :test,
      layout_profile: :capsule,
      groups: %i[contracts services],
      exports: [
        { name: :incident_runtime, kind: :service, target: "Services::IncidentRuntime" }
      ]
    )
    operator = Igniter::Application.capsule(:operator, root: File.join(root, "operator"), env: :test) do
      layout :capsule
      groups :contracts, :services
      export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
      import :incident_runtime, kind: :service, from: :incident_core
      import :audit_log, kind: :service, from: :host, capabilities: [:audit]
      import :optional_notifier, kind: :service, from: :observability, optional: true
      import :missing_policy, kind: :service, from: :host
    end

    report = Igniter::Application.compose_capsules(
      provider,
      operator,
      host_exports: [
        { name: :audit_log, kind: :service, target: "Host::AuditLog" }
      ],
      host_capabilities: [:audit],
      metadata: { source: :spec }
    ).to_h

    expect(report).to include(
      capsule_count: 2,
      host_capabilities: [:audit],
      ready: false,
      metadata: { source: :spec }
    )
    expect(report.fetch(:capsules).map { |entry| entry.fetch(:name) }).to eq(%i[incident_core operator])
    expect(report.fetch(:exports).map { |entry| entry.fetch(:name) }).to eq(%i[incident_runtime resolve_incident])
    expect(report.fetch(:satisfied_imports).map { |entry| entry.fetch(:name) }).to eq([:incident_runtime])
    expect(report.fetch(:satisfied_imports).first).to include(
      capsule: :operator,
      provider_capsule: :incident_core,
      satisfied_by: :capsule
    )
    expect(report.fetch(:host_satisfied_imports).map { |entry| entry.fetch(:name) }).to eq([:audit_log])
    expect(report.fetch(:unresolved_required_imports).map { |entry| entry.fetch(:name) }).to eq([:missing_policy])
    expect(report.fetch(:missing_optional_imports).map { |entry| entry.fetch(:name) }).to eq([:optional_notifier])
  end

  it "builds read-only capsule assembly plans with no mount intents" do
    root = File.expand_path("/tmp/igniter_capsule_assembly_empty")
    capsule = Igniter::Application.blueprint(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule,
      services: [:worker_queue]
    )

    plan = Igniter::Application.assemble_capsules(capsule, metadata: { source: :spec }).to_h

    expect(plan).to include(
      capsules: [:worker],
      composition_ready: true,
      mount_intents: [],
      unresolved_mount_intents: [],
      surfaces: [],
      ready: true,
      metadata: { source: :spec }
    )
    expect(plan.fetch(:composition).fetch(:ready)).to eq(true)
  end

  it "builds read-only capsule assembly plans with web mount intents and surface metadata" do
    root = File.expand_path("/tmp/igniter_capsule_assembly")
    provider = Igniter::Application.blueprint(
      name: :incident_core,
      root: File.join(root, "incident_core"),
      env: :test,
      layout_profile: :capsule,
      exports: [
        { name: :incident_runtime, kind: :service, target: "Services::IncidentRuntime" }
      ]
    )
    operator = Igniter::Application.capsule(:operator, root: File.join(root, "operator"), env: :test) do
      layout :capsule
      groups :contracts, :services
      export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
      import :incident_runtime, kind: :service, from: :incident_core
      import :audit_log, kind: :service, from: :host
    end
    surface_metadata = {
      name: :operator_console,
      kind: :web_surface,
      status: :aligned,
      flows: [:incident_review]
    }

    plan = Igniter::Application.assemble_capsules(
      provider,
      operator,
      host_exports: [
        { name: :audit_log, kind: :service, target: "Host::AuditLog" }
      ],
      mount_intents: [
        { capsule: :operator, kind: :web, at: "operator", capabilities: %i[screen stream] }
      ],
      surface_metadata: [surface_metadata]
    ).to_h

    expect(plan).to include(
      capsules: %i[incident_core operator],
      composition_ready: true,
      ready: true
    )
    expect(plan.fetch(:mount_intents)).to contain_exactly(
      include(capsule: :operator, kind: :web, at: "/operator", capabilities: %i[screen stream])
    )
    expect(plan.fetch(:surfaces)).to eq([surface_metadata])
    expect(plan.fetch(:composition).fetch(:host_satisfied_imports).map { |entry| entry.fetch(:name) }).to eq([:audit_log])
  end

  it "reports unresolved capsule names in mount intents without mounting anything" do
    root = File.expand_path("/tmp/igniter_capsule_assembly_unresolved")
    capsule = Igniter::Application.blueprint(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule
    )

    plan = Igniter::Application.assemble_capsules(
      capsule,
      mount_intents: [
        { capsule: :operator, kind: :web, at: "/operator" }
      ]
    ).to_h

    expect(plan).to include(composition_ready: true, ready: false)
    expect(plan.fetch(:unresolved_mount_intents)).to contain_exactly(
      include(capsule: :operator, kind: :web, at: "/operator")
    )
  end

  it "builds read-only capsule handoff manifests from explicit assembly metadata" do
    root = File.expand_path("/tmp/igniter_capsule_handoff")
    provider = Igniter::Application.blueprint(
      name: :incident_core,
      root: File.join(root, "incident_core"),
      env: :test,
      layout_profile: :capsule,
      exports: [
        { name: :incident_runtime, kind: :service, target: "Services::IncidentRuntime" }
      ]
    )
    operator = Igniter::Application.capsule(:operator, root: File.join(root, "operator"), env: :test) do
      layout :capsule
      groups :contracts, :services
      export :resolve_incident, kind: :contract, target: "Contracts::ResolveIncident"
      import :incident_runtime, kind: :service, from: :incident_core
      import :audit_log, kind: :service, from: :host, capabilities: [:audit]
      web_surface :operator_console
    end
    surface_metadata = {
      name: :operator_console,
      kind: :web_surface,
      status: :aligned,
      flows: [:incident_review]
    }

    manifest = Igniter::Application.handoff_manifest(
      subject: :operator_bundle,
      capsules: [provider, operator],
      host_exports: [
        { name: :audit_log, kind: :service, target: "Host::AuditLog" }
      ],
      host_capabilities: [:audit],
      mount_intents: [
        { capsule: :operator, kind: :web, at: "/operator", capabilities: [:screen] }
      ],
      surface_metadata: [surface_metadata],
      metadata: { source: :spec }
    ).to_h

    expect(manifest).to include(
      subject: :operator_bundle,
      ready: true,
      capsule_count: 2,
      metadata: { source: :spec }
    )
    expect(manifest.fetch(:capsules).map { |entry| entry.fetch(:name) }).to eq(%i[incident_core operator])
    expect(manifest.fetch(:readiness)).to include(
      composition_ready: true,
      assembly_ready: true,
      unresolved_required_count: 0,
      missing_optional_count: 0,
      unresolved_mount_count: 0
    )
    expect(manifest.fetch(:mount_intents).map { |entry| entry.fetch(:capsule) }).to eq([:operator])
    expect(manifest.fetch(:surfaces)).to eq([surface_metadata])
    expect(manifest.fetch(:suggested_host_wiring)).to eq([])
  end

  it "reports unresolved handoff requirements as suggested host wiring" do
    root = File.expand_path("/tmp/igniter_capsule_handoff_missing")
    capsule = Igniter::Application.capsule(:operator, root: root, env: :test) do
      layout :capsule
      import :audit_log, kind: :service, from: :host, capabilities: [:audit]
      import :optional_notifier, kind: :service, from: :observability, optional: true
    end

    manifest = Igniter::Application.handoff_manifest(
      subject: :operator_bundle,
      capsules: [capsule]
    ).to_h

    expect(manifest).to include(subject: :operator_bundle, ready: false)
    expect(manifest.fetch(:unresolved_required_imports).map { |entry| entry.fetch(:name) }).to eq([:audit_log])
    expect(manifest.fetch(:missing_optional_imports).map { |entry| entry.fetch(:name) }).to eq([:optional_notifier])
    expect(manifest.fetch(:suggested_host_wiring)).to contain_exactly(
      include(capsule: :operator, name: :audit_log, kind: :service, capabilities: [:audit])
    )
  end

  it "builds handoff manifests from an existing assembly plan" do
    root = File.expand_path("/tmp/igniter_capsule_handoff_existing_plan")
    capsule = Igniter::Application.blueprint(
      name: :worker,
      root: root,
      env: :test,
      layout_profile: :capsule
    )
    plan = Igniter::Application.assemble_capsules(capsule)

    manifest = Igniter::Application.handoff_manifest(
      subject: :worker_bundle,
      assembly_plan: plan
    ).to_h

    expect(manifest).to include(subject: :worker_bundle, ready: true, capsule_count: 1)
    expect(manifest.fetch(:capsules).map { |entry| entry.fetch(:name) }).to eq([:worker])
    expect(manifest.fetch(:assembly)).to eq(plan.to_h)
  end

  it "serializes agent-native flow session values without web dependencies" do
    event = Igniter::Application::FlowEvent.new(
      id: "event-1",
      session_id: "flow-1",
      type: :user_reply,
      source: :user,
      target: :clarification,
      payload: { text: "Check source citations first." },
      timestamp: Time.utc(2026, 4, 24, 12, 0, 0),
      metadata: { channel: :operator }
    )
    snapshot = Igniter::Application::FlowSessionSnapshot.new(
      session_id: "flow-1",
      flow_name: :plan_review,
      status: :waiting_for_user,
      current_step: :review_plan,
      pending_inputs: [
        { name: :clarification, input_type: :textarea, required: true, target: :review_plan }
      ],
      pending_actions: [
        { name: :approve_plan, action_type: :contract, target: "Contracts::ApprovePlan" }
      ],
      events: [event],
      artifacts: [
        { name: :draft_plan, artifact_type: :markdown, uri: "memory://draft-plan", summary: "Draft plan" }
      ],
      metadata: { owner: :operator },
      created_at: Time.utc(2026, 4, 24, 11, 59, 0),
      updated_at: Time.utc(2026, 4, 24, 12, 0, 0)
    )

    expect(event.to_h.keys).to contain_exactly(
      :id,
      :session_id,
      :type,
      :source,
      :target,
      :payload,
      :timestamp,
      :metadata
    )
    expect(snapshot.to_h.keys).to contain_exactly(
      :session_id,
      :flow_name,
      :status,
      :current_step,
      :pending_inputs,
      :pending_actions,
      :events,
      :artifacts,
      :metadata,
      :created_at,
      :updated_at
    )
    expect(snapshot.to_h).to include(
      session_id: "flow-1",
      flow_name: :plan_review,
      status: :waiting_for_user,
      current_step: :review_plan,
      pending_inputs: [
        include(name: :clarification, input_type: :textarea, required: true, target: :review_plan)
      ],
      pending_actions: [
        include(name: :approve_plan, action_type: :contract, target: "Contracts::ApprovePlan")
      ],
      artifacts: [
        include(name: :draft_plan, artifact_type: :markdown, uri: "memory://draft-plan")
      ]
    )
  end

  it "starts and resumes flow sessions through the application session store" do
    environment = described_class.new(profile: Igniter::Application.build_profile)

    snapshot = environment.start_flow(
      :plan_review,
      session_id: "plan-review/1",
      input: { plan_id: "plan-1" },
      current_step: :review_plan,
      pending_inputs: [
        { name: :clarification, input_type: :textarea, target: :review_plan }
      ],
      pending_actions: [
        { name: :approve_plan, action_type: :contract, target: "Contracts::ApprovePlan" }
      ],
      artifacts: [
        { name: :draft_plan, artifact_type: :markdown, uri: "memory://draft-plan" }
      ],
      metadata: { surface: :operator_console }
    )

    entry = environment.fetch_session("plan-review/1")
    expect(entry.kind).to eq(:flow)
    expect(entry.status).to eq(:waiting_for_user)
    expect(entry.payload).to include(
      session_id: "plan-review/1",
      flow_name: :plan_review,
      status: :waiting_for_user
    )
    expect(snapshot.events).to eq([])

    updated = environment.resume_flow(
      "plan-review/1",
      event: {
        id: "event-1",
        type: :user_reply,
        source: :user,
        target: :clarification,
        payload: { text: "Check source citations first." },
        metadata: { actor: :operator }
      }
    )

    updated_entry = environment.fetch_session("plan-review/1")
    expect(updated.events.map(&:type)).to eq([:user_reply])
    expect(updated_entry.payload.fetch(:events).first).to include(
      id: "event-1",
      session_id: "plan-review/1",
      type: :user_reply,
      source: :user,
      target: :clarification,
      payload: { text: "Check source citations first." },
      metadata: { actor: :operator }
    )
  end

  it "resumes a flow by explicitly clearing answered pending inputs" do
    environment = described_class.new(profile: Igniter::Application.build_profile)
    environment.start_flow(
      :plan_review,
      session_id: "plan-review/1",
      current_step: :review_plan,
      pending_inputs: [
        { name: :clarification, input_type: :textarea, target: :review_plan }
      ]
    )

    updated = environment.resume_flow(
      "plan-review/1",
      event: {
        id: "event-1",
        type: :user_reply,
        source: :user,
        target: :clarification,
        payload: { text: "Looks good." }
      },
      status: :active,
      pending_inputs: []
    )

    expect(updated.status).to eq(:active)
    expect(updated.pending_inputs).to eq([])
    expect(updated.events.map(&:type)).to eq([:user_reply])
    expect(environment.fetch_session("plan-review/1").payload).to include(
      status: :active,
      pending_inputs: []
    )
  end

  it "resumes a flow by explicitly completing a pending action" do
    environment = described_class.new(profile: Igniter::Application.build_profile)
    environment.start_flow(
      :plan_review,
      session_id: "plan-review/1",
      pending_actions: [
        { name: :approve_plan, action_type: :contract, target: "Contracts::ApprovePlan" }
      ]
    )

    updated = environment.resume_flow(
      "plan-review/1",
      event: {
        id: "event-1",
        type: :action_completed,
        source: :host,
        target: :approve_plan,
        payload: { approved: true }
      },
      status: :completed,
      pending_actions: [],
      artifacts: [
        { name: :approved_plan, artifact_type: :markdown, uri: "memory://approved-plan" }
      ]
    )

    expect(updated.status).to eq(:completed)
    expect(updated.pending_actions).to eq([])
    expect(updated.artifacts.map(&:name)).to eq([:approved_plan])
    expect(updated.events.map(&:type)).to eq([:action_completed])
    expect(environment.fetch_session("plan-review/1").status).to eq(:completed)
  end

  it "exposes typed flow session read models without promoting non-flow sessions" do
    environment = described_class.new(profile: Igniter::Application.build_profile)

    environment.start_flow(
      :plan_review,
      session_id: "plan-review/1",
      pending_inputs: [
        { "name" => "clarification", "input_type" => "textarea", "target" => "review_plan" }
      ],
      pending_actions: [
        { "name" => "approve_plan", "action_type" => "contract", "target" => "Contracts::ApprovePlan" }
      ]
    )
    environment.start_flow(:plan_review, session_id: "plan-review/2")
    environment.session_store.write(
      Igniter::Application::SessionEntry.new(
        id: "compose/1",
        kind: :compose,
        status: :completed,
        payload: { outputs: { total: 42 } }
      )
    )

    snapshot = environment.flow_session("plan-review/1")

    expect(snapshot).to be_a(Igniter::Application::FlowSessionSnapshot)
    expect(snapshot.pending_inputs.first.name).to eq(:clarification)
    expect(snapshot.pending_actions.first.target).to eq("Contracts::ApprovePlan")
    expect(environment.flow_sessions.map(&:session_id)).to eq(["plan-review/1", "plan-review/2"])
    expect { environment.flow_session("compose/1") }.to raise_error(ArgumentError, /not a flow session/)
  end

  it "publishes generic mount registrations without depending on mounted package classes" do
    operator_surface = Struct.new(:name).new("OperatorSurface")

    profile = Igniter::Application.build_kernel
                                  .manifest(:operator, root: "/tmp/igniter_operator", env: :test)
                                  .mount_web(
                                    :operator_console,
                                    operator_surface,
                                    at: "operator",
                                    capabilities: %i[screen stream],
                                    metadata: { interaction_model: :agent_operated }
                                  )
                                  .mount(
                                    :agent_bus,
                                    :agent_bus_adapter,
                                    kind: :agent,
                                    at: "/agents",
                                    capabilities: [:command]
                                  )
                                  .finalize
    environment = described_class.new(profile: profile)

    expect(profile.mount_names).to eq(%i[agent_bus operator_console])
    expect(environment.mount(:operator_console).to_h).to include(
      name: :operator_console,
      kind: :web,
      target: "OperatorSurface",
      at: "/operator",
      capabilities: %i[screen stream],
      metadata: { interaction_model: :agent_operated }
    )
    expect(environment.mounts_by_kind(:web).map(&:name)).to eq([:operator_console])
    expect(environment.manifest.to_h.fetch(:mounts)).to include(
      include(
        name: :operator_console,
        kind: :web,
        at: "/operator",
        capabilities: %i[screen stream]
      ),
      include(
        name: :agent_bus,
        kind: :agent,
        at: "/agents",
        capabilities: [:command]
      )
    )
    expect(environment.manifest.mounts).to all(be_a(Hash))
    expect(environment.manifest.mounts.first.keys).to contain_exactly(
      :name,
      :kind,
      :target,
      :at,
      :capabilities,
      :metadata
    )
    serialized_mounts = [
      environment.manifest.to_h.fetch(:mounts),
      profile.to_h.fetch(:mounts),
      environment.snapshot.to_h.fetch(:mounts)
    ].flatten
    expect(serialized_mounts).to all(be_a(Hash))
    expect(serialized_mounts).to all(include(:name, :kind, :target, :at, :capabilities, :metadata))
    expect(serialized_mounts.flat_map(&:keys).uniq).not_to include(
      :rack_app,
      :env,
      :page,
      :component,
      :arbre,
      :screen,
      :graph
    )
    expect(environment.snapshot.to_h.fetch(:mounts).map { |entry| entry.fetch(:name) }).to eq(
      %i[agent_bus operator_console]
    )
  end

  it "persists compose sessions through the application session store" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::ComposePack)
    pricing_graph = environment.compile do
      input :amount
      input :tax_rate

      compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
        amount + (amount * tax_rate)
      end

      output :total
    end

    result = environment.run_compose_session(
      session_id: "pricing/1",
      compiled_graph: pricing_graph,
      inputs: { amount: 100, tax_rate: 0.2 },
      metadata: { origin: :quote_preview }
    )
    entry = environment.fetch_session("pricing/1")

    expect(result.output(:total)).to eq(120.0)
    expect(entry.kind).to eq(:compose)
    expect(entry.status).to eq(:completed)
    expect(entry.metadata).to include(origin: :quote_preview)
    expect(entry.payload).to include(
      inputs: { amount: 100, tax_rate: 0.2 },
      outputs: { total: 120.0 },
      output_names: [:total]
    )
    expect(environment.snapshot.to_h.fetch(:runtime).fetch(:session_count)).to eq(1)
  end

  it "persists collection sessions through the application session store" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::CollectionPack)
    item_graph = environment.compile do
      input :sku
      input :amount
      input :tax_rate

      compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
        amount + (amount * tax_rate)
      end

      output :total
    end

    result = environment.run_collection_session(
      session_id: "pricing-collection/1",
      items: [
        { sku: "a", amount: 10 },
        { sku: "b", amount: 20 }
      ],
      compiled_graph: item_graph,
      key: :sku,
      inputs: { tax_rate: 0.2 },
      metadata: { origin: :quote_batch }
    )
    entry = environment.fetch_session("pricing-collection/1")

    expect(result.keys).to eq(%w[a b])
    expect(result.fetch("b").output(:total)).to eq(24.0)
    expect(entry.kind).to eq(:collection)
    expect(entry.status).to eq(:completed)
    expect(entry.metadata).to include(origin: :quote_batch, key: :sku)
    expect(entry.payload).to include(
      inputs: { tax_rate: 0.2 },
      item_count: 2,
      keys: %w[a b]
    )
    expect(entry.payload.fetch(:summary)).to include(total: 2, added: 2)
  end

  it "allows replacing the default session store seam" do
    custom_store = Class.new do
      attr_reader :written

      def initialize
        @written = {}
      end

      def write(entry)
        @written[entry.id] = entry
        entry
      end

      def fetch(id)
        @written.fetch(id.to_s)
      end

      def entries
        @written.values.sort_by(&:id)
      end
    end.new

    profile = Igniter::Application.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                                  .session_store(:custom, seam: custom_store)
                                  .finalize

    expect(profile.session_store_name).to eq(:custom)
    expect(profile.to_h.fetch(:session_store)).to eq(:custom)

    environment = described_class.new(profile: profile)
    graph = environment.compile do
      input :amount
      output :amount
    end
    environment.run_compose_session(
      session_id: "manual/1",
      compiled_graph: graph,
      inputs: { amount: 10 },
      metadata: { source: :manual_spec }
    )

    expect(custom_store.fetch("manual/1").payload).to include(outputs: { amount: 10 })
  end

  it "exposes application-owned compose invokers for contracts via:" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::ComposePack)

    result = environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: environment.compose_invoker(namespace: :quotes, metadata: { source: :dsl }) do
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :pricing_total
    end

    entry = environment.fetch_session("quotes/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.kind).to eq(:compose)
    expect(entry.status).to eq(:completed)
    expect(entry.metadata).to include(namespace: "quotes", source: :dsl, session_id: "quotes/pricing_total/1")
  end

  it "exposes application-owned collection invokers for contracts via:" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::CollectionPack)

    result = environment.run(inputs: {
                               items: [
                                 { sku: "a", amount: 10 },
                                 { sku: "b", amount: 20 }
                               ],
                               tax_rate: 0.2
                             }) do
      input :items
      input :tax_rate

      collection :priced_items,
                 from: :items,
                 key: :sku,
                 inputs: { tax_rate: :tax_rate },
                 via: environment.collection_invoker(namespace: :quotes, metadata: { source: :dsl }) do
        input :sku
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :priced_items
    end

    entry = environment.fetch_session("quotes/priced_items/1")

    expect(result.output(:priced_items).fetch("a").output(:total)).to eq(12.0)
    expect(entry.kind).to eq(:collection)
    expect(entry.status).to eq(:completed)
    expect(entry.metadata).to include(namespace: "quotes", source: :dsl, session_id: "quotes/priced_items/1")
  end

  it "records failed compose sessions in the session store" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::ComposePack)
    graph = environment.compile do
      input :amount
      output :amount
    end

    expect do
      environment.run_compose_session(
        session_id: "pricing/failure",
        compiled_graph: graph,
        inputs: { amount: 10 },
        invoker: ->(invocation:) { raise "transport unavailable for #{invocation.operation.name}" }
      )
    end.to raise_error(RuntimeError, /transport unavailable/)

    entry = environment.fetch_session("pricing/failure")

    expect(entry.status).to eq(:failed)
    expect(entry.payload.fetch(:error)).to include(
      class: "RuntimeError",
      message: "transport unavailable for pricing/failure"
    )
  end

  it "builds transport-ready remote compose invokers" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::ComposePack)
    requests = []
    transport = lambda do |request:|
      requests << request
      result = Igniter::Contracts.execute(
        request.compiled_graph,
        inputs: request.inputs,
        profile: environment.profile.contracts_profile
      )
      Igniter::Application::TransportResponse.new(
        result: result,
        metadata: { adapter: :stub_remote, target: "node-a" }
      )
    end

    result = environment.run(inputs: { subtotal: 50, rate: 0.1 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: environment.remote_compose_invoker(transport: transport, namespace: :mesh) do
        input :amount
        input :tax_rate
        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end
        output :total
      end

      output :pricing_total
    end

    entry = environment.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(55.0)
    expect(requests.length).to eq(1)
    expect(requests.first).to be_a(Igniter::Application::TransportRequest)
    expect(requests.first.kind).to eq(:compose)
    expect(requests.first.session_id).to eq("mesh/pricing_total/1")
    expect(entry.payload.fetch(:transport)).to eq(adapter: :stub_remote, target: "node-a")
  end

  it "builds transport-ready remote collection invokers" do
    environment = Igniter::Application.with(Igniter::Extensions::Contracts::CollectionPack)
    requests = []
    transport = lambda do |request:|
      requests << request
      result = Igniter::Extensions::Contracts::CollectionPack::LocalInvoker.call(
        invocation: Igniter::Extensions::Contracts::CollectionPack::Invocation.new(
          operation: Igniter::Contracts::Operation.new(kind: :collection, name: request.operation_name, attributes: {}),
          items: request.items,
          inputs: request.inputs,
          compiled_graph: request.compiled_graph,
          profile: environment.profile.contracts_profile,
          key_name: request.key_name,
          window: request.window
        )
      )
      Igniter::Application::TransportResponse.new(
        result: result,
        metadata: { adapter: :stub_remote, target: "node-b" }
      )
    end

    result = environment.run(inputs: {
                               items: [
                                 { sku: "a", amount: 10 },
                                 { sku: "b", amount: 20 }
                               ],
                               tax_rate: 0.2
                             }) do
      input :items
      input :tax_rate

      collection :priced_items,
                 from: :items,
                 key: :sku,
                 inputs: { tax_rate: :tax_rate },
                 via: environment.remote_collection_invoker(transport: transport, namespace: :mesh) do
        input :sku
        input :amount
        input :tax_rate
        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end
        output :total
      end

      output :priced_items
    end

    entry = environment.fetch_session("mesh/priced_items/1")

    expect(result.output(:priced_items).fetch("b").output(:total)).to eq(24.0)
    expect(requests.length).to eq(1)
    expect(requests.first.kind).to eq(:collection)
    expect(requests.first.session_id).to eq("mesh/priced_items/1")
    expect(requests.first.key_name).to eq(:sku)
    expect(entry.payload.fetch(:transport)).to eq(adapter: :stub_remote, target: "node-b")
  end

  it "keeps provider registry resolution separate from provider boot" do
    provider = LifecycleProvider.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .finalize
                                      .then { |profile| described_class.new(profile: profile) }

    expect(environment.service(:analytics_api).call).to eq("memory://analytics")
    expect(provider.boot_calls).to eq(0)
    expect(environment.provider_resolution_report.to_h).to include(
      phase: :resolve,
      status: :completed,
      providers: [:analytics],
      services: %i[analytics_api public_analytics_api],
      interfaces: [:public_analytics_api]
    )
  end

  it "builds a boot plan before execution" do
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, LifecycleProvider.new)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .contracts_path("contracts")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    plan = environment.plan_boot(base_dir: Dir.pwd, load_code: true, start_scheduler: false, activate_transport: false)

    expect(plan).to be_a(Igniter::Application::BootPlan)
    expect(plan.actions).to eq(%i[load_code resolve_providers boot_providers])
    expect(plan.load_code_step.to_h).to include(
      seam: :loader,
      action: :load,
      status: :planned
    )
    expect(plan.scheduler_step.to_h).to include(
      seam: :scheduler,
      action: :start,
      status: :skipped,
      reason: "start_scheduler disabled"
    )
    expect(plan.host_step.to_h).to include(
      seam: :host,
      action: :activate_transport,
      status: :skipped,
      reason: "activate_transport disabled"
    )
  end

  it "executes an explicit boot plan through the plan executor" do
    provider = LifecycleProvider.new
    scheduler = LifecycleScheduler.new
    loader = LifecycleLoader.new
    host = LifecycleHost.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .loader(:filesystem, seam: loader)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .contracts_path("contracts")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    plan = environment.plan_boot(base_dir: Dir.pwd, activate_transport: true)
    report = environment.execute_boot_plan(plan)

    expect(report.plan).to equal(plan)
    expect(environment.booted?).to be(true)
    expect(loader.loads.length).to eq(1)
    expect(scheduler.starts).to eq([:threaded])
    expect(host.activations).to eq(1)
    expect(provider.boot_calls).to eq(1)
  end

  it "boots through explicit provider lifecycle and returns structured reports" do
    provider = LifecycleProvider.new
    scheduler = LifecycleScheduler.new
    loader = LifecycleLoader.new
    host = LifecycleHost.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .loader(:filesystem, seam: loader)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .contracts_path("contracts")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    report = environment.boot(base_dir: Dir.pwd, activate_transport: true)

    expect(report).to be_a(Igniter::Application::BootReport)
    expect(report.plan).to be_a(Igniter::Application::BootPlan)
    expect(report.loaded_code?).to be(true)
    expect(report.providers_resolved?).to be(true)
    expect(report.providers_booted?).to be(true)
    expect(report.scheduler_started?).to be(true)
    expect(provider.boot_calls).to eq(1)
    expect(loader.loads.first).to include(
      base_dir: Dir.pwd,
      loader: :filesystem
    )
    expect(scheduler.starts).to eq([:threaded])
    expect(host.activations).to eq(1)
    expect(environment.service(:analytics_api).call).to eq("memory://analytics")
    expect(environment.interface(:public_analytics_api).call).to eq("memory://analytics")
    expect(report.loader_result.to_h).to include(
      seam: :loader,
      action: :load,
      status: :completed
    )
    expect(report.scheduler_result.to_h).to include(
      seam: :scheduler,
      action: :start,
      status: :completed
    )
    expect(report.host_result.to_h).to include(
      seam: :host,
      action: :activate_transport,
      status: :completed
    )
    expect(report.to_h.fetch(:plan).fetch(:actions)).to eq(
      %i[load_code resolve_providers boot_providers start_scheduler activate_transport]
    )
    expect(report.provider_resolution_report.to_h).to include(
      providers: [:analytics],
      services: %i[analytics_api public_analytics_api],
      interfaces: [:public_analytics_api]
    )
    expect(report.provider_boot_report.to_h).to include(
      phase: :boot,
      status: :completed,
      completed_providers: [:analytics]
    )
    expect(environment.snapshot.to_h.fetch(:runtime)).to include(
      providers_resolved: true,
      providers_booted: true,
      providers_shutdown: false,
      scheduler_running: true,
      transport_activated: true
    )
  end

  it "builds a shutdown plan from current runtime state" do
    provider = LifecycleProvider.new
    scheduler = LifecycleScheduler.new
    host = LifecycleHost.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    pre_boot_plan = environment.plan_shutdown
    expect(pre_boot_plan.actions).to eq([])
    expect(pre_boot_plan.host_step.to_h).to include(status: :skipped, reason: "transport not active")
    expect(pre_boot_plan.scheduler_step.to_h).to include(status: :skipped, reason: "scheduler not running")
    expect(pre_boot_plan.provider_shutdown_step.to_h).to include(status: :skipped, reason: "providers not booted")

    environment.boot(load_code: false, activate_transport: true)
    plan = environment.plan_shutdown

    expect(plan).to be_a(Igniter::Application::ShutdownPlan)
    expect(plan.actions).to eq(%i[deactivate_transport stop_scheduler shutdown_providers])
    expect(plan.host_step.to_h).to include(
      seam: :host,
      action: :deactivate_transport,
      status: :planned
    )
    expect(plan.scheduler_step.to_h).to include(
      seam: :scheduler,
      action: :stop,
      status: :planned
    )
    expect(plan.provider_shutdown_step.to_h).to include(
      seam: :providers,
      action: :shutdown,
      status: :planned
    )
  end

  it "executes an explicit shutdown plan through the plan executor" do
    provider = LifecycleProvider.new
    scheduler = LifecycleScheduler.new
    host = LifecycleHost.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    environment.boot(load_code: false, activate_transport: true)
    plan = environment.plan_shutdown
    report = environment.execute_shutdown_plan(plan)

    expect(report.plan).to equal(plan)
    expect(environment.booted?).to be(false)
    expect(host.deactivations).to eq(1)
    expect(scheduler.stops).to eq([:threaded])
    expect(provider.shutdown_calls).to eq(1)
  end

  it "shuts down providers through an explicit lifecycle report" do
    provider = LifecycleProvider.new
    scheduler = LifecycleScheduler.new
    host = LifecycleHost.new
    environment = Igniter::Application.build_kernel
                                      .register_provider(:analytics, provider)
                                      .scheduler(:threaded, seam: scheduler)
                                      .host(:rack, seam: host)
                                      .set(:runtime, :mode, value: :test)
                                      .set(:services, :analytics, :endpoint, value: "memory://analytics")
                                      .then { |kernel| described_class.new(profile: kernel.finalize) }

    environment.boot(load_code: false, activate_transport: true)
    report = environment.shutdown

    expect(report).to be_a(Igniter::Application::ShutdownReport)
    expect(report.plan).to be_a(Igniter::Application::ShutdownPlan)
    expect(report.transport_deactivated?).to be(true)
    expect(report.scheduler_stopped?).to be(true)
    expect(report.providers_shutdown?).to be(true)
    expect(provider.shutdown_calls).to eq(1)
    expect(host.deactivations).to eq(1)
    expect(scheduler.stops).to eq([:threaded])
    expect(report.host_result.to_h).to include(
      seam: :host,
      action: :deactivate_transport,
      status: :completed
    )
    expect(report.scheduler_result.to_h).to include(
      seam: :scheduler,
      action: :stop,
      status: :completed
    )
    expect(report.to_h.fetch(:plan).fetch(:actions)).to eq(
      %i[deactivate_transport stop_scheduler shutdown_providers]
    )
    expect(report.provider_shutdown_report.to_h).to include(
      phase: :shutdown,
      status: :completed,
      completed_providers: [:analytics]
    )
    expect(environment.snapshot.to_h.fetch(:runtime)).to include(
      booted: false,
      providers_booted: false,
      providers_shutdown: true,
      scheduler_running: false,
      transport_activated: false
    )
  end
end
