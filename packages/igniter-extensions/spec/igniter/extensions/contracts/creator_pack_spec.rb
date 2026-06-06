# frozen_string_literal: true

require "tmpdir"

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::CreatorPack do
  module DraftCreatorPack
    module_function

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :draft_creator_pack,
        node_contracts: [Igniter::Contracts::PackManifest.node(:draft)],
        registry_contracts: [Igniter::Contracts::PackManifest.validator(:draft_sources)]
      )
    end

    def install_into(kernel)
      kernel
    end
  end

  it "installs DebugPack as a dependency" do
    profile = Igniter::Extensions::Contracts.build_profile(described_class)

    expect(profile.pack_names).to include(:extensions_creator, :extensions_debug)
    expect(profile.pack_manifest(:extensions_creator).requires_packs.map(&:name)).to eq([:extensions_debug])
  end

  it "publishes available authoring profiles" do
    expect(Igniter::Extensions::Contracts.creator_profiles).to eq(
      %i[feature_node diagnostic_bundle operational_adapter bundle_pack]
    )
  end

  it "publishes available authoring scopes" do
    expect(Igniter::Extensions::Contracts.creator_scopes).to eq(
      %i[app_local monorepo_package standalone_gem]
    )
  end

  it "builds a feature scaffold with pack/spec/example/readme templates" do
    scaffold = Igniter::Extensions::Contracts.scaffold_pack(
      name: :slug,
      profile: :feature_node,
      scope: :monorepo_package,
      namespace: "Acme::IgniterPacks"
    )

    expect(scaffold.pack_constant).to eq("Acme::IgniterPacks::SlugPack")
    expect(scaffold.profile.name).to eq(:feature_node)
    expect(scaffold.scope.name).to eq(:monorepo_package)
    expect(scaffold.files.keys).to eq([
                                        "lib/acme/igniter_packs/slug_pack.rb",
                                        "spec/acme/igniter_packs/slug_pack_spec.rb",
                                        "examples/slug_pack.rb",
                                        "README.md"
                                      ])
    expect(scaffold.files.fetch("lib/acme/igniter_packs/slug_pack.rb")).to include("PackManifest.node(:slug)")
    expect(scaffold.files.fetch("examples/slug_pack.rb")).to include("audit_pack")
  end

  it "builds an operational scaffold with effect/executor templates" do
    scaffold = Igniter::Extensions::Contracts.scaffold_pack(
      name: :audit_trail,
      profile: :operational_adapter,
      scope: :standalone_gem,
      namespace: "Acme::IgniterPacks"
    )

    expect(scaffold.files.fetch("lib/acme/igniter_packs/audit_trail_pack.rb")).to include("PackManifest.effect(:audit_trail)")
    expect(scaffold.files.fetch("lib/acme/igniter_packs/audit_trail_pack.rb")).to include("PackManifest.executor(:audit_trail_inline)")
    expect(scaffold.files.fetch("lib/acme/igniter_packs/audit_trail_pack.rb")).not_to include("install_dependency_pack")
  end

  it "builds a diagnostic bundle scaffold with dependency and diagnostics hints" do
    scaffold = Igniter::Extensions::Contracts.scaffold_pack(
      name: :developer_console,
      profile: :diagnostic_bundle,
      scope: :monorepo_package,
      namespace: "Acme::IgniterPacks"
    )

    template = scaffold.files.fetch("lib/acme/igniter_packs/developer_console_pack.rb")

    expect(scaffold.kind).to eq(:bundle)
    expect(scaffold.profile.dependency_hints).to include(
      "Igniter::Extensions::Contracts::ExecutionReportPack",
      "Igniter::Extensions::Contracts::ProvenancePack"
    )
    expect(scaffold.profile.development_dependency_hints).to include(
      "Igniter::Extensions::Contracts::DebugPack"
    )
    expect(template).to include("PackManifest.diagnostic(:developer_console_summary)")
    expect(template).to include("requires_packs: [Igniter::Extensions::Contracts::ExecutionReportPack, Igniter::Extensions::Contracts::ProvenancePack]")
    expect(template).not_to include("install_dependency_pack")
  end

  it "adapts generated paths for app-local scope" do
    scaffold = Igniter::Extensions::Contracts.scaffold_pack(
      name: :slug,
      profile: :feature_node,
      scope: :app_local,
      namespace: "Acme::IgniterPacks"
    )

    expect(scaffold.pack_file_path).to eq("app/lib/acme/igniter_packs/slug_pack.rb")
    expect(scaffold.spec_file_path).to eq("spec/lib/acme/igniter_packs/slug_pack_spec.rb")
    expect(scaffold.readme_file_path).to eq("docs/igniter-packs/README.md")
  end

  it "infers an operational scaffold from capabilities" do
    scaffold = Igniter::Extensions::Contracts.scaffold_pack(
      name: :delivery,
      capabilities: %i[effect executor],
      namespace: "Acme::IgniterPacks"
    )

    expect(scaffold.kind).to eq(:operational)
    expect(scaffold.profile.capabilities).to eq(%i[effect executor])
  end

  it "builds a creator report and includes audit feedback when a pack is provided" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    report = Igniter::Extensions::Contracts.creator_report(
      name: :draft,
      profile: :feature_node,
      scope: :standalone_gem,
      namespace: "Acme::IgniterPacks",
      pack: DraftCreatorPack,
      target: environment
    )

    expect(report.scaffold.pack_constant).to eq("Acme::IgniterPacks::DraftPack")
    expect(report.audit.ok?).to eq(false)
    expect(report.next_steps).to include("use Igniter::Extensions::Contracts.audit_pack(...) before finalize")
    expect(report.next_steps.grep(/implement node kind/)).not_to be_empty
    expect(report.next_steps.grep(/distributable gem/)).not_to be_empty
    expect(report.to_h.fetch(:quality_bar).fetch(:includes_example)).to eq(true)
  end

  it "builds a creator workflow with ordered stages and packaging guidance" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    workflow = Igniter::Extensions::Contracts.creator_workflow(
      name: :draft,
      profile: :feature_node,
      scope: :standalone_gem,
      namespace: "Acme::IgniterPacks",
      pack: DraftCreatorPack,
      target: environment
    )

    expect(workflow.current_stage.key).to eq(:implement_pack)
    expect(workflow.current_stage.status).to eq(:needs_attention)
    expect(workflow.ready_for_packaging?).to eq(false)
    expect(workflow.recommended_packs.fetch(:development)).to include("Igniter::Extensions::Contracts::DebugPack")
    expect(workflow.to_h.fetch(:stages).map { |stage| stage.fetch(:key) }).to eq(
      %i[select_profile generate_scaffold implement_pack validate_pack package_pack]
    )
  end

  it "builds a creator wizard with pending decisions and upgrades into a writer" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    wizard = Igniter::Extensions::Contracts.creator_wizard(
      name: :slug,
      capabilities: %i[effect executor],
      target: environment
    )

    completed = wizard.apply(scope: :standalone_gem)

    expect(wizard.ready_for_workflow?).to eq(false)
    expect(wizard.current_decision.fetch(:key)).to eq(:scope)
    expect(wizard.branching_hints.grep(/JournalPack/)).not_to be_empty
    expect(wizard.recommended_examples).to include("examples/contracts/build_effect_executor_pack.rb")
    expect(wizard.authoring_profile.kind).to eq(:operational)
    expect(completed.ready_for_workflow?).to eq(true)
    expect(completed.ready_for_writer?).to eq(true)
    expect(completed.writer.plan.steps.any? { |step| step.kind == :file }).to eq(true)
  end

  it "surfaces diagnostic bundle branching hints and runtime pack recommendations" do
    wizard = Igniter::Extensions::Contracts.creator_wizard(
      name: :developer_console,
      profile: :diagnostic_bundle
    )

    expect(wizard.recommended_packs.fetch(:runtime)).to include(
      "Igniter::Extensions::Contracts::ExecutionReportPack",
      "Igniter::Extensions::Contracts::ProvenancePack"
    )
    expect(wizard.branching_hints.grep(/DebugPack/)).not_to be_empty
    expect(wizard.recommended_examples).to include("examples/contracts/debug.rb")
  end

  it "writes a scaffold through a multi-step writer and preserves existing files in safe mode" do
    Dir.mktmpdir("igniter-creator-writer") do |dir|
      writer = Igniter::Extensions::Contracts.creator_writer(
        name: :slug,
        profile: :feature_node,
        scope: :monorepo_package,
        namespace: "Acme::IgniterPacks",
        root: dir
      )

      plan = writer.plan
      result = writer.write

      pack_path = File.join(dir, "lib/acme/igniter_packs/slug_pack.rb")
      File.write(pack_path, "# custom\n")

      second_result = writer.write

      expect(plan.steps.any? { |step| step.kind == :directory && step.status == :pending }).to eq(true)
      expect(result.success?).to eq(true)
      expect(File.exist?(pack_path)).to eq(true)
      expect(second_result.files_skipped).to be >= 1
      expect(File.read(pack_path)).to eq("# custom\n")
    end
  end
end
