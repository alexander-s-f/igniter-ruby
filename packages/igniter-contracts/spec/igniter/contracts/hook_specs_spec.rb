# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::HookSpecs do
  it "declares hook roles and return policies for mature seams" do
    normalizer = described_class.fetch(:normalizers)
    validator = described_class.fetch(:validators)
    runtime_handler = described_class.fetch(:runtime_handlers)
    effect = described_class.fetch(:effects)
    executor = described_class.fetch(:executors)

    expect(normalizer.role).to eq(:graph_transformer)
    expect(normalizer.return_policy).to eq(:operations_array)
    expect(validator.role).to eq(:validator)
    expect(validator.return_policy).to eq(:validation_findings)
    expect(runtime_handler.role).to eq(:runtime_handler)
    expect(runtime_handler.return_policy).to eq(:value)
    expect(effect.role).to eq(:effect_adapter)
    expect(effect.return_policy).to eq(:opaque)
    expect(effect.required_keywords).to eq([:invocation])
    expect(executor.role).to eq(:executor)
    expect(executor.return_policy).to eq(:execution_result)
    expect(executor.required_keywords).to eq([:invocation])
  end
end
