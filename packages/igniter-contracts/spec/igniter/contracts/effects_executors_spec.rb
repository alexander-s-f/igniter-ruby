# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts effects and executors" do
  module AuditEffectPack
    module_function

    AUDIT_EFFECT = lambda do |invocation:|
      {
        payload: invocation.payload,
        context: invocation.context.to_h,
        profile: invocation.profile.fingerprint
      }
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :audit_effect,
        registry_contracts: [Igniter::Contracts::PackManifest.effect(:audit)]
      )
    end

    def install_into(kernel)
      kernel.effects.register(:audit, AUDIT_EFFECT)
      kernel
    end
  end

  module InvalidExecutorPack
    module_function

    INVALID_EXECUTOR = lambda do |compiled_graph:|
      compiled_graph
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :invalid_executor,
        registry_contracts: [Igniter::Contracts::PackManifest.executor(:invalid_executor)]
      )
    end

    def install_into(kernel)
      kernel.executors.register(:invalid_executor, INVALID_EXECUTOR)
      kernel
    end
  end

  module BadResultExecutorPack
    module_function

    BAD_EXECUTOR = lambda do |invocation:|
      {
        compiled_graph: invocation.compiled_graph,
        inputs: invocation.inputs,
        profile: invocation.profile,
        runtime: invocation.runtime
      }
    end

    def manifest
      Igniter::Contracts::PackManifest.new(
        name: :bad_result_executor,
        registry_contracts: [Igniter::Contracts::PackManifest.executor(:bad_result)]
      )
    end

    def install_into(kernel)
      kernel.executors.register(:bad_result, BAD_EXECUTOR)
      kernel
    end
  end

  it "applies registered effects through the profile seam" do
    profile = Igniter::Contracts.build_kernel.install(AuditEffectPack).finalize

    result = Igniter::Contracts.apply_effect(
      :audit,
      payload: { amount: 10 },
      context: { source: :spec },
      profile: profile
    )

    expect(result).to eq(
      payload: { amount: 10 },
      context: { source: :spec },
      profile: profile.fingerprint
    )
  end

  it "raises a contracts-owned error for unknown effects" do
    expect do
      Igniter::Contracts.apply_effect(:missing, payload: {}, context: {})
    end.to raise_error(Igniter::Contracts::UnknownEffectError, /unknown effect missing/)
  end

  it "rejects executors whose callable signature does not match the hookspec" do
    kernel = Igniter::Contracts.build_kernel.install(InvalidExecutorPack)

    expect { kernel.finalize }
      .to raise_error(Igniter::Contracts::InvalidHookImplementationError,
                      /executors entry invalid_executor.*invocation:/)
  end

  it "rejects executor results that violate the execution_result policy" do
    profile = Igniter::Contracts.build_kernel.install(BadResultExecutorPack).finalize
    compiled = Igniter::Contracts.compile(profile: profile) do
      input :amount
      output :amount
    end

    expect do
      Igniter::Contracts.execute_with(:bad_result, compiled, inputs: { amount: 10 }, profile: profile)
    end.to raise_error(
      Igniter::Contracts::InvalidHookResultError,
      /executors entry bad_result \(executor\) must return an ExecutionResult/
    )
  end

  it "raises a contracts-owned error for unknown executors" do
    compiled = Igniter::Contracts.compile do
      input :amount
      output :amount
    end

    expect do
      Igniter::Contracts.execute_with(:missing, compiled, inputs: { amount: 10 })
    end.to raise_error(Igniter::Contracts::UnknownExecutorError, /unknown executor missing/)
  end
end
