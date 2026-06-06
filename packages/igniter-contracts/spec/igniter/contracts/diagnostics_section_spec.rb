# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Contracts::DiagnosticsSection do
  it "wraps hash values as typed named values" do
    section = described_class.new(
      name: "baseline_summary",
      value: { outputs: [:amount], state: [:amount] }
    )

    expect(section.name).to eq(:baseline_summary)
    expect(section.value).to be_a(Igniter::Contracts::NamedValues)
    expect(section.value.fetch(:outputs)).to eq([:amount])
    expect(section).to be_frozen
  end
end
