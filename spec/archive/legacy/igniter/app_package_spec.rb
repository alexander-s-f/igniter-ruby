# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-app/lib/igniter-app"

RSpec.describe "igniter-app local gem facade" do
  it "re-exports the app runtime and scaffold packs from the local package" do
    expect(Igniter::App).to be_a(Class)
    expect(Igniter::App::Kernel).to be_a(Class)
    expect(Igniter::App::Profile).to be_a(Class)
    expect(Igniter::App::Snapshot).to be_a(Class)
    expect(Igniter::App::BootReport).to be_a(Class)
    expect(Igniter::App::Environment).to be_a(Class)
    expect(Igniter::App::Generator).to be_a(Class)
    expect(Igniter::App::HostRegistry.registered?(:app)).to be(true)
    expect(Igniter::App::HostRegistry.registered?(:cluster_app)).to be(true)
  end
end
