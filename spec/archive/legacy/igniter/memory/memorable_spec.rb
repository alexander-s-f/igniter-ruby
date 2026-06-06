# frozen_string_literal: true

require "igniter/core/memory"

RSpec.describe Igniter::Memory::Memorable do
  after { Igniter::Memory.reset! }

  # ── test host classes ──────────────────────────────────────────────────────

  let(:store) { Igniter::Memory::Stores::InMemory.new }

  let(:base_class) do
    Class.new do
      include Igniter::Memory::Memorable
    end
  end

  let(:enabled_class) do
    s = store
    Class.new do
      include Igniter::Memory::Memorable
      enable_memory store: s
    end
  end

  # ── memory_enabled? ───────────────────────────────────────────────────────

  describe ".memory_enabled?" do
    it "is false by default" do
      expect(base_class.memory_enabled?).to be false
    end

    it "is true after calling enable_memory" do
      expect(enabled_class.memory_enabled?).to be true
    end
  end

  # ── enable_memory ────────────────────────────────────────────────────────

  describe ".enable_memory" do
    it "sets the memory store on the class" do
      expect(enabled_class.memory_store).to be(store)
    end

    it "falls back to Igniter::Memory.default_store when no store passed" do
      klass = Class.new { include Igniter::Memory::Memorable }
      klass.enable_memory
      expect(klass.memory_store).to be(Igniter::Memory.default_store)
    end
  end

  # ── #memory instance method ───────────────────────────────────────────────

  describe "#memory" do
    it "returns an AgentMemory" do
      instance = enabled_class.new
      expect(instance.memory).to be_a(Igniter::Memory::AgentMemory)
    end

    it "is memoized (same object on repeated calls)" do
      instance = enabled_class.new
      expect(instance.memory).to be(instance.memory)
    end

    it "includes the class name in the agent_id" do
      named_class = Class.new do
        include Igniter::Memory::Memorable
      end
      stub_const("MyNamedAgent", named_class)
      named_class.enable_memory store: Igniter::Memory::Stores::InMemory.new

      instance = named_class.new
      # We record and check the episode's agent_id
      ep = instance.memory.record(type: :t, content: "x")
      expect(ep.agent_id).to include("MyNamedAgent")
    end

    it "includes the object_id in the agent_id for instance isolation" do
      inst1 = enabled_class.new
      inst2 = enabled_class.new

      id1 = inst1.memory.record(type: :t, content: "a").agent_id
      id2 = inst2.memory.record(type: :t, content: "b").agent_id
      expect(id1).not_to eq(id2)
    end
  end

  # ── inheritance ───────────────────────────────────────────────────────────

  describe "inheritance" do
    let(:parent_class) do
      s = store
      klass = Class.new do
        include Igniter::Memory::Memorable
        enable_memory store: s
      end
      klass
    end

    let(:child_class) { Class.new(parent_class) }

    it "child inherits memory_enabled? from parent" do
      expect(child_class.memory_enabled?).to be true
    end

    it "child inherits memory_store from parent" do
      expect(child_class.memory_store).to be(store)
    end

    it "child can override its own store independently" do
      child_store = Igniter::Memory::Stores::InMemory.new
      child_class.enable_memory store: child_store
      expect(child_class.memory_store).to be(child_store)
      expect(parent_class.memory_store).to be(store)
    end
  end
end
