# frozen_string_literal: true

require "spec_helper"
require "igniter/agent"
require "igniter/registry"

RSpec.describe Igniter::Registry do
  let(:agent_class) do
    Class.new(Igniter::Agent) do
      on(:ping) { |**| :pong }
    end
  end

  let(:ref) { agent_class.start }

  before { Igniter::Registry.clear }
  after  do
    Igniter::Registry.clear
    begin
      ref.stop
    rescue StandardError
      nil
    end
  end

  describe ".register" do
    it "stores a ref under a name" do
      Igniter::Registry.register(:my_agent, ref)
      expect(Igniter::Registry.find(:my_agent)).to be(ref)
    end

    it "raises RegistryError on duplicate name" do
      Igniter::Registry.register(:my_agent, ref)
      expect { Igniter::Registry.register(:my_agent, ref) }
        .to raise_error(Igniter::Registry::RegistryError, /already registered/)
    end
  end

  describe ".register!" do
    it "replaces an existing registration without raising" do
      ref2 = agent_class.start
      Igniter::Registry.register!(:my_agent, ref)
      Igniter::Registry.register!(:my_agent, ref2)
      expect(Igniter::Registry.find(:my_agent)).to be(ref2)
      ref2.stop
    end
  end

  describe ".find" do
    it "returns nil when name not registered" do
      expect(Igniter::Registry.find(:missing)).to be_nil
    end
  end

  describe ".fetch" do
    it "returns the ref when registered" do
      Igniter::Registry.register(:my_agent, ref)
      expect(Igniter::Registry.fetch(:my_agent)).to be(ref)
    end

    it "raises RegistryError when not registered" do
      expect { Igniter::Registry.fetch(:missing) }
        .to raise_error(Igniter::Registry::RegistryError, /No agent registered/)
    end
  end

  describe ".registered?" do
    it "returns false before registration" do
      expect(Igniter::Registry.registered?(:my_agent)).to be false
    end

    it "returns true after registration" do
      Igniter::Registry.register(:my_agent, ref)
      expect(Igniter::Registry.registered?(:my_agent)).to be true
    end

    it "returns false after unregister" do
      Igniter::Registry.register(:my_agent, ref)
      Igniter::Registry.unregister(:my_agent)
      expect(Igniter::Registry.registered?(:my_agent)).to be false
    end
  end

  describe ".unregister" do
    it "removes the registration and returns the ref" do
      Igniter::Registry.register(:my_agent, ref)
      returned = Igniter::Registry.unregister(:my_agent)
      expect(returned).to be(ref)
      expect(Igniter::Registry.find(:my_agent)).to be_nil
    end
  end

  describe ".all" do
    it "returns a snapshot of all registrations" do
      ref2 = agent_class.start
      Igniter::Registry.register(:a, ref)
      Igniter::Registry.register(:b, ref2)
      all = Igniter::Registry.all
      expect(all.keys).to contain_exactly(:a, :b)
      ref2.stop
    end
  end

  describe ".clear" do
    it "removes all registrations" do
      Igniter::Registry.register(:my_agent, ref)
      Igniter::Registry.clear
      expect(Igniter::Registry.all).to be_empty
    end
  end

  describe "thread safety" do
    it "handles concurrent registrations without data corruption" do
      refs = Array.new(10) { agent_class.start }
      threads = refs.each_with_index.map do |r, i|
        Thread.new { Igniter::Registry.register(:"agent_#{i}", r) }
      end
      threads.each(&:join)
      expect(Igniter::Registry.all.size).to eq(10)
      refs.each(&:stop)
    end
  end

  describe "Agent.start with name:" do
    it "auto-registers the agent in the registry" do
      r = agent_class.start(name: :auto_named)
      expect(Igniter::Registry.find(:auto_named)).to be(r)
      r.stop
      Igniter::Registry.unregister(:auto_named)
    end
  end
end
