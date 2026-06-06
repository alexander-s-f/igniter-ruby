# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Extensions::Contracts::Language::PiecewisePack do
  it "lowers piecewise decisions into observable compute nodes" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { training_minutes: 50 }) do
      input :training_minutes

      piecewise :training_score, on: :training_minutes do
        eq 0, id: :none, value: 0
        between 1..45, id: :moderate, value: 10
        between 46..90, id: :heavy, value: 2
        default id: :overload, value: -12
      end

      output :training_score
    end

    expect(result.output(:training_score)).to eq(2)
    expect(result.state.fetch(:training_score_decision)).to include(
      case: :heavy,
      matcher: :between,
      matched_on: 46..90,
      selector: :training_minutes,
      selector_value: 50,
      value: 2
    )
  end

  it "can compute case values from dependent inputs without hiding the selected case" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { score: 9, multiplier: 3 }) do
      input :score
      input :multiplier

      piecewise :bonus, on: :score, depends_on: [:multiplier] do
        between 0..10, id: :scaled do |score:, multiplier:|
          score * multiplier
        end
        default id: :none, value: 0
      end

      output :bonus
    end

    expect(result.output(:bonus)).to eq(27)
    expect(result.state.fetch(:bonus_decision)).to include(case: :scaled, value: 27)
  end
end
