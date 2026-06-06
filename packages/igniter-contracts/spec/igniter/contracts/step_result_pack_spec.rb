# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::StepResultPack do
  it "is optional and keeps baseline unaware of step" do
    expect do
      Igniter::Contracts.compile do
        input :params
        step :validated_params, depends_on: [:params] do |params:|
          params
        end
        output :validated_params
      end
    end.to raise_error(Igniter::Contracts::UnknownDslKeywordError, /unknown DSL keyword step/)
  end

  it "normalizes raw step returns into serializable success results" do
    profile = Igniter::Contracts.build_profile(described_class)
    compiled = Igniter::Contracts.compile(profile: profile) do
      input :params
      step :validated_params, depends_on: [:params] do |params:|
        params.merge(valid: true)
      end
      output :validated_params
    end

    result = Igniter::Contracts.execute(compiled, inputs: { params: { name: "Alex" } }, profile: profile)
    step_result = result.output(:validated_params)

    expect(step_result).to be_success
    expect(step_result.value).to eq(name: "Alex", valid: true)
    expect(step_result.to_h).to eq(
      success: true,
      value: { name: "Alex", valid: true },
      failure: nil,
      metadata: {}
    )
  end

  it "passes explicit failures through and short-circuits dependent steps" do
    profile = Igniter::Contracts.build_profile(described_class)
    market_resolver = Class.new do
      def self.call(validated_params:)
        Igniter::Contracts::StepResult.failure(
          code: :market_not_found,
          message: "market was not found",
          details: { market_id: validated_params.fetch(:market_id) }
        )
      end
    end
    business_window_checker = Class.new do
      def self.call(market:, clock:)
        { market: market, clock: clock }
      end
    end

    compiled = Igniter::Contracts.compile(profile: profile) do
      input :params
      input :clock
      step :validated_params, depends_on: [:params] do |params:|
        params
      end
      step :market, depends_on: [:validated_params], call: market_resolver
      step :business_window, depends_on: %i[market clock], call: business_window_checker
      output :business_window
    end

    result = Igniter::Contracts.execute(
      compiled,
      inputs: { params: { market_id: "north" }, clock: "09:00" },
      profile: profile
    )

    market = result.state.fetch(:market)
    business_window = result.output(:business_window)

    expect(market).to be_failure
    expect(market.failure).to eq(
      code: :market_not_found,
      message: "market was not found",
      details: { market_id: "north" }
    )
    expect(business_window).to be_failure
    expect(business_window.failure).to eq(
      code: :halted_dependency,
      message: "step business_window halted because dependency market failed",
      details: {
        dependency: :market,
        failure: {
          code: :market_not_found,
          message: "market was not found",
          details: { market_id: "north" }
        }
      }
    )
  end

  it "exposes an ordered serializable diagnostics step trace" do
    profile = Igniter::Contracts.build_profile(described_class)
    compiled = Igniter::Contracts.compile(profile: profile) do
      input :params
      step :validated_params, depends_on: [:params] do |params:|
        Igniter::Contracts::StepResult.failure(
          code: :invalid_params,
          message: "params are invalid",
          details: { keys: params.keys }
        )
      end
      step :market, depends_on: [:validated_params] do |validated_params:|
        validated_params
      end
      output :market
    end

    result = Igniter::Contracts.execute(compiled, inputs: { params: { market_id: nil } }, profile: profile)
    report = Igniter::Contracts.diagnose(result, profile: profile)

    expect(report.section(:step_trace)).to eq([
                                                {
                                                  name: :validated_params,
                                                  status: :failed,
                                                  dependencies: [:params],
                                                  failure: {
                                                    code: :invalid_params,
                                                    message: "params are invalid",
                                                    details: { keys: [:market_id] }
                                                  }
                                                },
                                                {
                                                  name: :market,
                                                  status: :failed,
                                                  dependencies: [:validated_params],
                                                  failure: {
                                                    code: :halted_dependency,
                                                    message: "step market halted because dependency validated_params failed",
                                                    details: {
                                                      dependency: :validated_params,
                                                      failure: {
                                                        code: :invalid_params,
                                                        message: "params are invalid",
                                                        details: { keys: [:market_id] }
                                                      }
                                                    }
                                                  }
                                                }
                                              ])
  end

  it "validates missing step dependencies and callables" do
    profile = Igniter::Contracts.build_profile(described_class)

    expect do
      Igniter::Contracts.compile(profile: profile) do
        step :market, depends_on: [:validated_params]
        output :market
      end
    end.to raise_error(Igniter::Contracts::ValidationError) { |error|
      expect(error.message).to include("step dependencies are not defined: validated_params")
      expect(error.message).to include("step nodes require a callable: market")
    }
  end
end
