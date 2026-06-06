# frozen_string_literal: true

require_relative "../../spec_helper"
require "igniter/embed/rails"

RSpec.describe Igniter::Embed::Rails do
  it "is safe to require and install outside Rails with an explicit reloader" do
    callbacks = []
    reloader = Class.new do
      define_method(:initialize) { |store| @store = store }
      define_method(:to_prepare) { |&block| @store << block }
    end.new(callbacks)

    contracts = Igniter::Embed.configure(:sparkcrm)

    described_class.install(contracts, reloader: reloader, cache: false)

    expect(contracts.config.cache).to eq(false)
    expect(callbacks.length).to eq(1)
  end

  it "clears the container cache through a host reloader callback" do
    callbacks = []
    reloader = Class.new do
      define_method(:initialize) { |store| @store = store }
      define_method(:to_prepare) { |&block| @store << block }
    end.new(callbacks)
    compile_count = 0
    contracts = Igniter::Embed.configure(:billing) do |config|
      config.cache = true
    end
    contracts.register(:quote) do
      compile_count += 1
      input :amount
      output :amount
    end
    described_class.install(contracts, reloader: reloader)

    contracts.call(:quote, amount: 1)
    contracts.call(:quote, amount: 2)
    expect(compile_count).to eq(1)

    callbacks.first.call
    contracts.call(:quote, amount: 3)

    expect(compile_count).to eq(2)
  end

  it "raises an Igniter-owned error for invalid reloaders" do
    contracts = Igniter::Embed.configure(:sparkcrm)

    expect do
      described_class.install(contracts, reloader: Object.new)
    end.to raise_error(Igniter::Embed::RailsIntegrationError, /reloader/)
  end
end
