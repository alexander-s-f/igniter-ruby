# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Extensions::Contracts::Language::FormulaPack do
  it "builds observable formulas from dependency values" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { sleep_score: 38, training_score: 10 }) do
      input :sleep_score
      input :training_score

      formula :body_score do
        base 45
        add :sleep_score
        add :training_score
        clamp 0, 100
        round
      end

      output :body_score
    end

    expect(result.output(:body_score)).to eq(93)
    expect(result.state.fetch(:body_score_trace)).to include(
      value: 93,
      dependencies: %i[sleep_score training_score]
    )
    expect(result.state.fetch(:body_score_trace).fetch(:steps).map { |step| step.fetch(:operation) }).to eq(
      %i[base add add clamp round]
    )
  end

  it "can start from a dependency with from" do
    environment = Igniter::Extensions::Contracts.with(described_class)

    result = environment.run(inputs: { subtotal: 100 }) do
      input :subtotal

      formula :discounted do
        from :subtotal
        subtract 15
        clamp 0, 100
      end

      output :discounted
    end

    expect(result.output(:discounted)).to eq(85.0)
    expect(result.state.fetch(:discounted_trace).fetch(:dependencies)).to eq([:subtotal])
  end
end
