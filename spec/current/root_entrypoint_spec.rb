# frozen_string_literal: true

require "spec_helper"

RSpec.describe "root igniter entrypoint" do
  it "loads the active contracts-native facade" do
    expect(Igniter::Contracts).to be_a(Module)
    expect(Igniter::Embed).to be_a(Module)
    expect(Igniter::Application).to be_a(Module)
    expect(Igniter.with).to be_a(Igniter::Contracts::Environment)
    expect(Igniter.embed(:test)).to be_a(Igniter::Embed::Container)
    expect(Igniter.application).to be_a(Igniter::Application::Environment)
  end

  it "archives legacy root contract entrypoints" do
    expect { require "igniter/contract" }
      .to raise_error(LoadError, /archived/)
  end
end
