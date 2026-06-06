# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts assembly/execution namespaces" do
  it "exposes assembly infrastructure through the Assembly namespace and root aliases" do
    expect(Igniter::Contracts::Assembly::Kernel).to equal(Igniter::Contracts::Kernel)
    expect(Igniter::Contracts::Assembly::Profile).to equal(Igniter::Contracts::Profile)
    expect(Igniter::Contracts::Assembly::PackManifest).to equal(Igniter::Contracts::PackManifest)
    expect(Igniter::Contracts::Assembly::HookSpecs).to equal(Igniter::Contracts::HookSpecs)
  end

  it "exposes execution runtime through the Execution namespace and root aliases" do
    expect(Igniter::Contracts::Execution::Builder).to equal(Igniter::Contracts::Builder)
    expect(Igniter::Contracts::Execution::Compiler).to equal(Igniter::Contracts::Compiler)
    expect(Igniter::Contracts::Execution::Runtime).to equal(Igniter::Contracts::Runtime)
    expect(Igniter::Contracts::Execution::Diagnostics).to equal(Igniter::Contracts::Diagnostics)
  end
end
