# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-core/lib/igniter-core"

RSpec.describe "igniter-core local gem facade" do
  it "re-exports the core entrypoint and version from the local package" do
    expect(Igniter::VERSION).to be_a(String)
    expect(Igniter::Tool.superclass).to eq(Igniter::Executor)
    expect(Igniter::StreamLoop).to be_a(Class)
  end
end
