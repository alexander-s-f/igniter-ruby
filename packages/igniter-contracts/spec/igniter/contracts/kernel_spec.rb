# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Kernel do
  it "installs the baseline pack through build_kernel" do
    kernel = Igniter::Contracts.build_kernel

    expect(kernel.nodes.fetch(:input)).to be_a(Igniter::Contracts::NodeType)
    expect(kernel.nodes.fetch(:input).kind).to eq(:input)
    expect(kernel.nodes.fetch(:const).kind).to eq(:const)
    expect(kernel.nodes.fetch(:effect).kind).to eq(:effect)
    expect(kernel.dsl_keywords.fetch(:compute)).to be_a(Igniter::Contracts::DslKeyword)
    expect(kernel.dsl_keywords.fetch(:effect)).to be_a(Igniter::Contracts::DslKeyword)
    expect(kernel.runtime_handlers.fetch(:output)).to respond_to(:call)
  end

  it "installs additional packs directly through build_kernel" do
    kernel = Igniter::Contracts.build_kernel(Igniter::Contracts::ProjectPack)

    expect(kernel.nodes.fetch(:const).kind).to eq(:const)
    expect(kernel.dsl_keywords.fetch(:project)).to be_a(Igniter::Contracts::DslKeyword)
  end

  it "finalizes into an immutable profile" do
    kernel = Igniter::Contracts.build_kernel

    profile = kernel.finalize

    expect(profile).to be_a(Igniter::Contracts::Profile)
    expect(profile.supports_node_kind?(:const)).to be(true)
    expect(profile.supports_node_kind?(:branch)).to be(false)
    expect(profile.normalizers.map(&:key)).to include(:normalize_operation_attributes)
    expect(profile.pack_names).to eq([:baseline])
    expect(profile.fingerprint).not_to be_empty
    expect(kernel).to be_finalized
  end

  it "rejects pack installation after finalization" do
    kernel = Igniter::Contracts.build_kernel
    kernel.finalize

    expect { kernel.install(Igniter::Contracts::BaselinePack) }
      .to raise_error(Igniter::Contracts::FrozenKernelError, /kernel already finalized/)
  end

  it "memoizes default kernel and profile until reset" do
    first_kernel = Igniter::Contracts.default_kernel
    first_profile = Igniter::Contracts.default_profile

    expect(Igniter::Contracts.default_kernel).to equal(first_kernel)
    expect(Igniter::Contracts.default_profile).to equal(first_profile)

    Igniter::Contracts.reset_defaults!

    expect(Igniter::Contracts.default_kernel).not_to equal(first_kernel)
    expect(Igniter::Contracts.default_profile).not_to equal(first_profile)
  end

  it "allows explicit kernels to install additional packs before finalization" do
    kernel = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack)

    expect(kernel.nodes.registered?(:project)).to be(false)
    expect(kernel.dsl_keywords.fetch(:project)).to be_a(Igniter::Contracts::DslKeyword)
    expect(kernel.dsl_keywords.fetch(:const)).to be_a(Igniter::Contracts::DslKeyword)
  end

  it "builds a finalized profile through build_profile" do
    profile = Igniter::Contracts.build_profile(Igniter::Contracts::ProjectPack)

    expect(profile).to be_a(Igniter::Contracts::Profile)
    expect(profile.pack_names).to eq(%i[baseline project])
  end

  it "auto-installs manifest-declared pack dependencies" do
    dependency_pack = Module.new do
      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :dependency_pack,
          registry_contracts: [Igniter::Contracts::PackManifest.dsl_keyword(:dependency_marker)]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel.dsl_keywords.register(:dependency_marker, Igniter::Contracts::DslKeyword.new(:dependency_marker) do |_name, builder:|
          builder
        end)
        kernel
      end
    end

    dependent_pack = Module.new do
      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :dependent_pack,
          requires_packs: [dependency_pack]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel
      end
    end

    profile = Igniter::Contracts.build_profile(dependent_pack)

    expect(profile.pack_names).to include(:dependency_pack, :dependent_pack)
    expect(profile.dsl_keyword(:dependency_marker)).to be_a(Igniter::Contracts::DslKeyword)
  end

  it "rejects missing concrete implementations for unknown dependency edges" do
    dependent_pack = Module.new do
      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :dependent_pack,
          requires_packs: [:missing_pack]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel
      end
    end

    expect do
      Igniter::Contracts.build_kernel.install(dependent_pack)
    end.to raise_error(Igniter::Contracts::UnknownPackDependencyError, /requires pack missing_pack/)
  end

  it "rejects circular pack dependencies" do
    first_pack = Module.new
    second_pack = Module.new

    first_pack.define_singleton_method(:manifest) do
      Igniter::Contracts::PackManifest.new(
        name: :first_pack,
        requires_packs: [Igniter::Contracts::PackManifest.pack_dependency(:second_pack, pack: second_pack)]
      )
    end
    first_pack.define_singleton_method(:install_into) { |kernel| kernel }

    second_pack.define_singleton_method(:manifest) do
      Igniter::Contracts::PackManifest.new(
        name: :second_pack,
        requires_packs: [Igniter::Contracts::PackManifest.pack_dependency(:first_pack, pack: first_pack)]
      )
    end
    second_pack.define_singleton_method(:install_into) { |kernel| kernel }

    expect do
      Igniter::Contracts.build_kernel.install(first_pack)
    end.to raise_error(Igniter::Contracts::CircularPackDependencyError, /first_pack -> second_pack -> first_pack/)
  end
end
