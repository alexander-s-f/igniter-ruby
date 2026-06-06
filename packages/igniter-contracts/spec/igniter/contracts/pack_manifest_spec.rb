# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::PackManifest do
  it "normalizes node contracts to symbol kinds with required capabilities by default" do
    contract = described_class.node("project")

    expect(contract.kind).to eq(:project)
    expect(contract.requires_dsl).to be(true)
    expect(contract.requires_runtime).to be(true)
  end

  it "stores pack metadata as immutable capability declarations" do
    manifest = described_class.new(
      name: "project",
      node_contracts: [described_class.node(:project)],
      registry_contracts: [
        described_class.validator("project_sources"),
        described_class.normalizer(:normalize_projection)
      ],
      diagnostics: ["projection_summary"],
      metadata: { category: :data }
    )

    expect(manifest.name).to eq(:project)
    expect(manifest.diagnostics).to eq([:projection_summary])
    expect(manifest.declared_keys_for(:validators)).to eq([:project_sources])
    expect(manifest.declared_keys_for(:normalizers)).to eq([:normalize_projection])
    expect(manifest.metadata).to eq({ category: :data })
    expect(manifest).to be_frozen
  end

  it "normalizes pack dependencies and capabilities" do
    dependency_pack = Module.new do
      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(name: :dependency_pack)
      end
    end

    manifest = described_class.new(
      name: :dependent_pack,
      requires_packs: [dependency_pack, :other_pack],
      provides_capabilities: %w[incremental diagnostics],
      requires_capabilities: [:pure, "dataflow"]
    )

    expect(manifest.requires_packs.map(&:name)).to eq(%i[dependency_pack other_pack])
    expect(manifest.requires_packs.first.pack).to eq(dependency_pack)
    expect(manifest.provides_capabilities).to eq(%i[incremental diagnostics])
    expect(manifest.requires_capabilities).to eq(%i[pure dataflow])
  end

  it "allows explicit dependency names for forward references and cycles" do
    dependency_pack = Module.new

    manifest = described_class.new(
      name: :dependent_pack,
      requires_packs: [
        described_class.pack_dependency(:dependency_pack, pack: dependency_pack)
      ]
    )

    expect(manifest.requires_packs.map(&:name)).to eq([:dependency_pack])
    expect(manifest.requires_packs.first.pack).to eq(dependency_pack)
  end
end
