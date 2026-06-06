# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::Contractable do
  class ContractableSpecBodyBattery
    include Igniter::Contracts::Contractable

    contractable :call do
      role :migration_candidate
      stage :shadowed
      meta :domain, :wellness
      input :sleep_hours
      input :training_minutes
      output :score
    end

    def call(sleep_hours:, training_minutes:)
      sleep_score = observe(:sleep_score) do
        [[sleep_hours / 8.0, 1.0].min * 40, 0].max
      end
      training_score = observe(:training_score) do
        training_minutes <= 45 ? 10 : 2
      end

      success(score: [[45 + sleep_score + training_score, 100].min, 0].max.round)
    end
  end

  it "wraps service objects with success outputs and observations" do
    result = described_class.invoke(ContractableSpecBodyBattery, sleep_hours: 7.5, training_minutes: 30)

    expect(result).to be_success
    expect(result.metadata).to eq(role: :migration_candidate, stage: :shadowed, domain: :wellness)
    expect(result.outputs).to eq(score: 93)
    expect(result.observations.map(&:to_h)).to include(
      include(name: :sleep_score, value: 37.5),
      include(name: :training_score, value: 10)
    )
  end

  it "makes contractable services callable from compute using" do
    result = Igniter::Contracts.with.run(inputs: { sleep_hours: 7.5, training_minutes: 30 }) do
      input :sleep_hours
      input :training_minutes
      compute :body_battery, depends_on: %i[sleep_hours training_minutes], using: ContractableSpecBodyBattery
      output :body_battery
    end

    payload = result.output(:body_battery)
    expect(payload).to include(status: :success, success: true)
    expect(payload.fetch(:metadata)).to include(role: :migration_candidate, stage: :shadowed, domain: :wellness)
    expect(payload.fetch(:outputs)).to eq(score: 93)
    expect(payload.fetch(:observations).map { |entry| entry.fetch(:name) }).to eq(%i[sleep_score training_score])
  end

  it "extracts a named contractable output when compute using declares output" do
    result = Igniter::Contracts.with.run(inputs: { sleep_hours: 7.5, training_minutes: 30 }) do
      input :sleep_hours
      input :training_minutes
      compute :score, depends_on: %i[sleep_hours training_minutes], using: ContractableSpecBodyBattery, output: :score
      output :score
    end

    expect(result.output(:score)).to eq(93)
  end

  it "keeps the failure payload when compute using output cannot extract a successful value" do
    service = Class.new do
      include Igniter::Contracts::Contractable

      contractable :call do
        output :score
      end

      def call
        failure(code: :not_ready, message: "not ready")
      end
    end

    result = Igniter::Contracts.with.run(inputs: {}) do
      compute :score, using: service, output: :score
      output :score
    end

    expect(result.output(:score)).to include(status: :failure, success: false)
    expect(result.output(:score).fetch(:error)).to include(code: :not_ready)
  end

  it "returns a failure result when declared inputs are missing" do
    result = described_class.invoke(ContractableSpecBodyBattery, sleep_hours: 7.5)

    expect(result).to be_failure
    expect(result.metadata).to include(role: :migration_candidate, stage: :shadowed, domain: :wellness)
    expect(result.error).to include(
      code: :contractable_missing_inputs,
      inputs: [:training_minutes]
    )
  end

  it "returns a failure result when declared outputs are missing" do
    service = Class.new do
      include Igniter::Contracts::Contractable

      contractable :call do
        output :score
      end

      def call
        success(value: 10)
      end
    end

    result = described_class.invoke(service)

    expect(result).to be_failure
    expect(result.outputs).to eq(value: 10)
    expect(result.error).to include(
      code: :contractable_missing_outputs,
      outputs: [:score]
    )
  end

  it "normalizes raised service errors into failure payloads" do
    service = Class.new do
      include Igniter::Contracts::Contractable

      def call
        raise "boom"
      end
    end

    result = described_class.invoke(service)

    expect(result).to be_failure
    expect(result.error).to include(code: :contractable_error, message: "boom")
  end
end
