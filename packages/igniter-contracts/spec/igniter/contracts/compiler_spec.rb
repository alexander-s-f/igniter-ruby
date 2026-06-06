# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Compiler do
  it "rejects duplicate non-output node names" do
    expect do
      Igniter::Contracts.compile do
        input :amount
        compute :amount, depends_on: [:amount] do |amount:|
          amount
        end
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /duplicate node names: amount/)
  end

  it "rejects outputs that point at undefined nodes" do
    expect do
      Igniter::Contracts.compile do
        output :missing_total
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /output targets are not defined: missing_total/)
  end

  it "exposes structured validation findings on compiler errors" do
    expect do
      Igniter::Contracts.compile do
        output :missing_total
      end
    end.to raise_error(Igniter::Contracts::ValidationError) { |error|
      expect(error.findings.map(&:code)).to eq([:missing_output_targets])
      expect(error.findings.first.subjects).to eq([:missing_total])
    }
  end

  it "rejects compute dependencies that are not defined" do
    expect do
      Igniter::Contracts.compile do
        compute :tax, depends_on: [:amount] do |amount:|
          amount * 0.2
        end
        output :tax
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /compute dependencies are not defined: amount/)
  end

  it "normalizes dependency names through the baseline normalizer seam" do
    compiled = Igniter::Contracts.compile do
      input :amount
      compute :tax, depends_on: ["amount"] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    expect(compiled.operations[1].attributes[:depends_on]).to eq([:amount])
  end

  it "builds a structured validation report without raising" do
    report = Igniter::Contracts.validation_report do
      compute :tax, depends_on: [:amount] do |amount:|
        amount * 0.2
      end
      output :missing_total
    end

    expect(report).to be_a(Igniter::Contracts::ValidationReport)
    expect(report).to be_invalid
    expect(report.findings.map(&:code)).to eq(%i[missing_output_targets missing_compute_dependencies])
  end

  it "builds a compilation report with normalized operations and compiled graph on success" do
    report = Igniter::Contracts.compilation_report do
      input :amount
      compute :tax, depends_on: ["amount"] do |amount:|
        amount * 0.2
      end
      output :tax
    end

    expect(report).to be_a(Igniter::Contracts::CompilationReport)
    expect(report).to be_ok
    expect(report.operations[1].attributes[:depends_on]).to eq([:amount])
    expect(report.compiled_graph).to be_a(Igniter::Contracts::CompiledGraph)
  end

  it "rejects branch as a non-baseline DSL keyword" do
    expect do
      Igniter::Contracts.compile do
        input :amount
        branch :tax_logic, on: :amount
        output :amount
      end
    end.to raise_error(Igniter::Contracts::UnknownDslKeywordError, /unknown DSL keyword branch/)
  end

  it "lowers project nodes into compute semantics and uses baseline dependency validation" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        project :country, from: :pricing, key: :country
        output :country
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /compute dependencies are not defined: pricing/)
  end

  it "compiles project DSL into a compute operation" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :pricing
      project :country, from: :pricing, key: :country
      output :country
    end

    expect(compiled.operations.map(&:kind)).to eq(%i[input compute output])
    expect(compiled.operations[1].name).to eq(:country)
    expect(compiled.operations[1].attributes[:depends_on]).to eq([:pricing])
    expect(compiled.operations[1].attributes[:callable]).to respond_to(:call)
  end

  it "compiles project dig paths into a compute operation" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :pricing
      project :country, from: :pricing, dig: %i[billing address country]
      output :country
    end

    expect(compiled.operations.map(&:kind)).to eq(%i[input compute output])
    expect(compiled.operations[1].attributes[:depends_on]).to eq([:pricing])
    expect(compiled.operations[1].attributes[:callable]).to respond_to(:call)
  end

  it "rejects project declarations that pass both key: and dig:" do
    profile = Igniter::Contracts.build_kernel.install(Igniter::Contracts::ProjectPack).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        input :pricing
        project :country, from: :pricing, key: :country, dig: %i[billing country]
        output :country
      end
    end.to raise_error(ArgumentError, /either key: or dig:/)
  end

  it "rejects effect nodes whose dependencies are not defined" do
    effect_pack = Module.new do
      extend Igniter::Contracts::Pack

      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :audit_effect,
          registry_contracts: [Igniter::Contracts::PackManifest.effect(:audit)]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel.effects.register(:audit, ->(invocation:) { invocation.payload })
        kernel
      end
    end
    profile = Igniter::Contracts.build_kernel.install(effect_pack).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        effect :audit_entry, using: :audit, depends_on: [:amount] do |amount:|
          { amount: amount }
        end
        output :audit_entry
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /effect dependencies are not defined: amount/)
  end

  it "rejects effect nodes without a payload callable" do
    effect_pack = Module.new do
      extend Igniter::Contracts::Pack

      define_singleton_method(:manifest) do
        Igniter::Contracts::PackManifest.new(
          name: :audit_effect,
          registry_contracts: [Igniter::Contracts::PackManifest.effect(:audit)]
        )
      end

      define_singleton_method(:install_into) do |kernel|
        kernel.effects.register(:audit, ->(invocation:) { invocation.payload })
        kernel
      end
    end
    profile = Igniter::Contracts.build_kernel.install(effect_pack).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        input :amount
        effect :audit_entry, using: :audit, depends_on: [:amount]
        output :audit_entry
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /effect nodes require a payload callable: audit_entry/)
  end

  it "rejects effect nodes whose named adapter is not installed in the profile" do
    expect do
      Igniter::Contracts.compile do
        input :amount
        effect :audit_entry, using: :audit, depends_on: [:amount] do |amount:|
          { amount: amount }
        end
        output :audit_entry
      end
    end.to raise_error(Igniter::Contracts::ValidationError, /effect adapters are not registered in profile: audit/)
  end
end
