# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-application/lib/igniter-application"

RSpec.describe "igniter-application local gem facade" do
  it "re-exports the clean contracts-native application runtime package" do
    expect(Igniter::Application).to be_a(Module)
    expect(Igniter::Application::Kernel).to be_a(Class)
    expect(Igniter::Application::Profile).to be_a(Class)
    expect(Igniter::Application::Environment).to be_a(Class)
    expect(Igniter::Application::Config).to be_a(Class)
    expect(Igniter::Application::ConfigBuilder).to be_a(Class)
    expect(Igniter::Application::Provider).to be_a(Class)
    expect(Igniter::Application::ProviderRegistration).to be_a(Class)
    expect(Igniter::Application::ServiceDefinition).to be_a(Class)
    expect(Igniter::Application::Interface).to be_a(Class)
    expect(Igniter::Application::ServiceRegistry).to be_a(Class)
    expect(Igniter::Application::ContractRegistry).to be_a(Class)
    expect(Igniter::Application::BootPhase).to be_a(Class)
    expect(Igniter::Application::Snapshot).to be_a(Class)
    expect(Igniter::Application::BootReport).to be_a(Class)
  end
end
