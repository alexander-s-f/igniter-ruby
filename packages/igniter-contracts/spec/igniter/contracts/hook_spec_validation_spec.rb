# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts hook spec validation" do
  module InvalidNormalizerResultPack
    module_function

    INVALID_NORMALIZER = lambda do |operations:, profile:| # rubocop:disable Lint/UnusedBlockArgument
      operations.first
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_normalizer_result,
        registry_contracts: [Igniter::Contracts::PackManifest.normalizer(:invalid_normalizer_result)]
      )
    end

    def install_into(kernel)
      kernel.normalizers.register(:invalid_normalizer_result, INVALID_NORMALIZER)
      kernel
    end
  end

  module InvalidValidatorPack
    module_function

    INVALID_VALIDATOR = lambda do |operations:|
      operations
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_validator,
        registry_contracts: [Igniter::Contracts::PackManifest.validator(:invalid_validator)]
      )
    end

    def install_into(kernel)
      kernel.validators.register(:invalid_validator, INVALID_VALIDATOR)
      kernel
    end
  end

  module InvalidDiagnosticsPack
    module_function

    CONTRIBUTOR = Module.new do
      module_function

      def augment(report:, result:) # rubocop:disable Lint/UnusedMethodArgument
        report.add_section(:invalid, {})
      end
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_diagnostics,
        registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:invalid_diagnostics)]
      )
    end

    def install_into(kernel)
      kernel.diagnostics_contributors.register(:invalid_diagnostics, CONTRIBUTOR)
      kernel
    end
  end

  module InvalidDslPack
    module_function

    INVALID_KEYWORD = lambda do |name|
      name
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_dsl,
        node_contracts: [Igniter::Contracts::PackManifest.node(:bad_keyword, requires_runtime: false)]
      )
    end

    def install_into(kernel)
      kernel.nodes.register(:bad_keyword,
                            Igniter::Contracts::NodeType.new(kind: :bad_keyword, metadata: { requires_runtime: false }))
      kernel.dsl_keywords.register(:bad_keyword, INVALID_KEYWORD)
      kernel
    end
  end

  module InvalidEffectPack
    module_function

    INVALID_EFFECT = lambda do |payload:|
      payload
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_effect,
        registry_contracts: [Igniter::Contracts::PackManifest.effect(:invalid_effect)]
      )
    end

    def install_into(kernel)
      kernel.effects.register(:invalid_effect, INVALID_EFFECT)
      kernel
    end
  end

  it "rejects validators whose callable signature does not match the hookspec" do
    kernel = Igniter::Contracts.build_kernel.install(InvalidValidatorPack)

    expect { kernel.finalize }
      .to raise_error(Igniter::Contracts::InvalidHookImplementationError,
                      /validators entry invalid_validator.*profile:/)
  end

  it "rejects diagnostics contributors whose augment signature does not match the hookspec" do
    kernel = Igniter::Contracts.build_kernel.install(InvalidDiagnosticsPack)

    expect { kernel.finalize }
      .to raise_error(Igniter::Contracts::InvalidHookImplementationError,
                      /diagnostics_contributors entry invalid_diagnostics.*profile:/)
  end

  it "rejects DSL keywords that do not accept the builder keyword" do
    kernel = Igniter::Contracts.build_kernel.install(InvalidDslPack)

    expect { kernel.finalize }
      .to raise_error(Igniter::Contracts::InvalidHookImplementationError, /dsl_keywords entry bad_keyword.*builder:/)
  end

  it "rejects effects that do not accept the invocation keyword" do
    kernel = Igniter::Contracts.build_kernel.install(InvalidEffectPack)

    expect { kernel.finalize }
      .to raise_error(Igniter::Contracts::InvalidHookImplementationError, /effects entry invalid_effect.*invocation:/)
  end

  it "rejects normalizer results that violate the graph transformer policy" do
    profile = Igniter::Contracts.build_kernel.install(InvalidNormalizerResultPack).finalize

    expect do
      Igniter::Contracts.compile(profile: profile) do
        input :amount
        output :amount
      end
    end.to raise_error(
      Igniter::Contracts::InvalidHookResultError,
      /normalizers entry invalid_normalizer_result \(graph_transformer\) must return an Array of operations/
    )
  end
end
