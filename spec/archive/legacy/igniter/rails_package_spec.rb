# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-rails/lib/igniter-rails"

RSpec.describe "igniter-rails local gem facade" do
  it "re-exports the Rails integration plugin from the local package" do
    expect(Igniter::Rails).to be_a(Module)
    expect(Igniter::Rails::ContractJob).to be_a(Class)
    expect(Igniter::Rails::WebhookHandler).to be_a(Module)
  end
end
