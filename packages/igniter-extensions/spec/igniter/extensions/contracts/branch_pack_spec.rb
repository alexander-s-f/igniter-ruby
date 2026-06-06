# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::BranchPack do
  it "adds branch DSL that lowers into compute semantics" do
    profile = Igniter::Contracts.build_kernel
                                .install(Igniter::Contracts::ProjectPack)
                                .install(described_class)
                                .finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :country
      branch :delivery_strategy, on: :country do
        on "UA", id: :local, value: :local
        default value: :international
      end
      project :delivery_mode, from: :delivery_strategy, key: :value
      output :delivery_mode
    end

    result = Igniter::Contracts.execute(compiled, inputs: { country: "UA" }, profile: profile)

    expect(profile.pack_names).to include(:baseline, :project, :extensions_branch)
    expect(profile.dsl_keyword(:branch)).to be_a(Igniter::Contracts::DslKeyword)
    expect(profile.supports_node_kind?(:branch)).to be(false)
    expect(compiled.operations.map(&:kind)).to eq(%i[input compute compute output])
    expect(result.output(:delivery_mode)).to eq(:local)
    expect(result.state.fetch(:delivery_strategy)).to include(
      case: :local,
      value: :local,
      matcher: :eq,
      selector: :country,
      selector_value: "UA"
    )
  end

  it "supports in: and matches: routing with callable case values" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :country
      input :vip
      branch :delivery_strategy, on: :country, depends_on: [:vip] do
        on in: %w[CA MX], id: :regional, value: :regional
        on matches: /\A[A-Z]{2}\z/, id: :international do |vip:|
          vip ? :priority_international : :international
        end
        default value: :fallback
      end
      output :delivery_strategy
    end

    result = Igniter::Contracts.execute(
      compiled,
      inputs: { country: "DE", vip: true },
      profile: profile
    )

    expect(result.output(:delivery_strategy)).to include(
      case: :international,
      value: :priority_international,
      matcher: :matches,
      selector_value: "DE"
    )
  end

  it "uses the explicit default case when nothing matches" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :country
      branch :delivery_strategy, on: :country do
        on "UA", value: :local
        default value: :international
      end
      output :delivery_strategy
    end

    result = Igniter::Contracts.execute(compiled, inputs: { country: "BR" }, profile: profile)

    expect(result.output(:delivery_strategy)).to include(
      case: :default,
      value: :international,
      matcher: :default,
      matched_on: :default
    )
  end

  it "rejects branch declarations without a default clause" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        input :country
        branch :delivery_strategy, on: :country do
          on "UA", value: :local
        end
        output :delivery_strategy
      end
    end.to raise_error(ArgumentError, /requires a default clause/)
  end

  it "rejects overlapping literal matches" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        input :country
        branch :delivery_strategy, on: :country do
          on "UA", value: :local
          on in: %w[UA PL], value: :regional
          default value: :international
        end
        output :delivery_strategy
      end
    end.to raise_error(ArgumentError, /overlapping literal matches: "UA"/)
  end

  it "uses baseline dependency validation when the selector is missing" do
    profile = Igniter::Contracts.build_kernel.install(described_class).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        branch :delivery_strategy, on: :country do
          on "UA", value: :local
          default value: :international
        end
        output :delivery_strategy
      end
    end.to raise_error(Igniter::Contracts::ValidationError) { |error|
      expect(error.findings.map(&:code)).to eq([:missing_compute_dependencies])
      expect(error.findings.first.subjects).to eq([:country])
    }
  end
end
