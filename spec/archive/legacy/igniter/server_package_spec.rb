# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-server/lib/igniter-server"

RSpec.describe "igniter-server local gem facade" do
  it "re-exports the server runtime from the local package" do
    expect(Igniter::Server).to be_a(Module)
    expect(Igniter::Server::Config).to be_a(Class)
    expect(Igniter::Server::ApplicationConfigProjection).to be_a(Class)
    expect(Igniter::Server::Registry).to be_a(Class)
    expect(Igniter::Server::ApplicationHost).to be_a(Class)
  end
end
