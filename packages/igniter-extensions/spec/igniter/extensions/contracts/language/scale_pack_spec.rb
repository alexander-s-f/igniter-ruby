# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Extensions::Contracts::Language::ScalePack do
  it "lowers numeric scale steps into observable compute nodes" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { sleep_hours: 7.5 }) do
      input :sleep_hours

      scale :sleep_score, from: :sleep_hours do
        divide_by 8
        clamp 0, 1
        multiply_by 40
        round
      end

      output :sleep_score
    end

    expect(result.output(:sleep_score)).to eq(38)
    expect(result.state.fetch(:sleep_score_trace)).to include(
      source: :sleep_hours,
      source_value: 7.5,
      value: 38
    )
    expect(result.state.fetch(:sleep_score_trace).fetch(:steps).map { |step| step.fetch(:operation) }).to eq(
      %i[divide_by clamp multiply_by round]
    )
  end

  it "keeps invalid numeric sources observable instead of raising from the contract" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { sleep_hours: "unknown" }) do
      input :sleep_hours

      scale :sleep_score, from: :sleep_hours do
        divide_by 8
      end

      output :sleep_score
    end

    expect(result.output(:sleep_score)).to eq(0.0)
    expect(result.state.fetch(:sleep_score_trace)).to include(error: :invalid_numeric_source)
  end
end
