# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-extensions/lib/igniter-extensions"

RSpec.describe "igniter-extensions package" do
  it "loads the package facade and namespace entrypoint" do
    expect(defined?(Igniter)).to eq("constant")
    expect(Igniter::Extensions).to be_a(Module)
  end
end
