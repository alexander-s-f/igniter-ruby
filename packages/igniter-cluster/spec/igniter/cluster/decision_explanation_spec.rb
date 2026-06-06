# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::DecisionExplanation do
  it "normalizes string explanations into explicit value objects" do
    explanation = described_class.normalize(
      "capability route to pricing_node",
      default_code: :capability_route,
      metadata: { mode: :capability }
    )

    expect(explanation.to_h).to eq(
      code: :capability_route,
      message: "capability route to pricing_node",
      metadata: { mode: :capability }
    )
  end

  it "preserves existing explanation objects" do
    explanation = described_class.new(code: :accepted, message: "accepted", metadata: { peer: :node_a })

    expect(described_class.normalize(explanation, default_code: :ignored)).to be(explanation)
  end
end
