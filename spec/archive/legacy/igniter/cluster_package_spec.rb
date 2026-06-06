# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-cluster/lib/igniter-cluster"

RSpec.describe "igniter-cluster local gem facade" do
  it "re-exports the cluster runtime from the local package" do
    expect(Igniter::Cluster).to be_a(Module)
    expect(Igniter::Cluster::Mesh).to be_a(Module)
    expect(Igniter::Cluster::RemoteAdapter).to be_a(Class)
  end
end
