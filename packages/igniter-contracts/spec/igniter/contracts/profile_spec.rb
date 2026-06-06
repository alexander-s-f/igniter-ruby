# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Profile do
  it "exposes installed pack names from finalized manifests" do
    profile = Igniter::Contracts.build_kernel
                                .install(Igniter::Contracts::ConstPack)
                                .install(Igniter::Contracts::ProjectPack)
                                .finalize

    expect(profile.pack_names).to eq(%i[baseline const project])
  end

  it "answers declared registry capabilities from installed pack manifests" do
    profile = Igniter::Contracts.build_kernel
                                .install(Igniter::Contracts::ProjectPack)
                                .finalize

    expect(profile.pack_manifest(:project)).not_to be_nil
    expect(profile.declared_registry_keys(:dsl_keywords)).to include(:project)
    expect(profile.declared_registry_keys(:diagnostics_contributors)).to include(:baseline_summary)
    expect(profile.declared_registry_keys(:executors)).to include(:inline)
    expect(profile.supports_executor?(:inline)).to be(true)
  end

  it "aggregates provided and required capabilities from installed pack manifests" do
    capability_pack = Module.new do
      module_function

      def manifest
        Igniter::Contracts::PackManifest.new(
          name: :capability_pack,
          provides_capabilities: %i[incremental traceable],
          requires_capabilities: %i[pure dataflow]
        )
      end

      def install_into(kernel)
        kernel
      end
    end

    profile = Igniter::Contracts.build_kernel
                                .install(capability_pack)
                                .finalize

    expect(profile.provided_capabilities).to eq(%i[incremental traceable])
    expect(profile.required_capabilities).to eq(%i[pure dataflow])
  end
end
