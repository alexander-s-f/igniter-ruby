# frozen_string_literal: true

require "spec_helper"
require "igniter/core/tool"
require "igniter/ai"

RSpec.describe Igniter::AI::Skill do
  # ── Minimal concrete skill (no LLM needed in unit tests) ──────────────────
  let(:greeter_skill) do
    Class.new(described_class) do
      description "Greet a user by name with a personalised message"
      param :name, type: :string, required: true, desc: "The user's first name"
      param :formal, type: :boolean, required: false, default: false, desc: "Use formal tone"

      def call(name:, formal: false)
        formal ? "Good day, #{name}." : "Hey #{name}!"
      end
    end
  end

  let(:research_skill) do
    Class.new(described_class) do
      description "Research a topic in depth"
      param :topic, type: :string, required: true, desc: "What to research"
      requires_capability :network

      def call(topic:) = "Research result for: #{topic}"
    end
  end

  # ── DSL ────────────────────────────────────────────────────────────────────

  describe ".description" do
    it "stores and retrieves the description" do
      expect(greeter_skill.description).to eq("Greet a user by name with a personalised message")
    end

    it "returns nil when not set" do
      klass = Class.new(described_class)
      expect(klass.description).to be_nil
    end
  end

  describe ".param" do
    it "records param name, type, required, desc" do
      p = greeter_skill.tool_params.find { |x| x[:name] == :name }
      expect(p).to include(name: :name, type: :string, required: true)
    end

    it "records optional params with defaults" do
      p = greeter_skill.tool_params.find { |x| x[:name] == :formal }
      expect(p).to include(required: false, default: false)
    end

    it "accumulates multiple params" do
      expect(greeter_skill.tool_params.map { |p| p[:name] }).to eq(%i[name formal])
    end
  end

  describe ".requires_capability" do
    it "stores required capabilities" do
      expect(research_skill.required_capabilities).to eq([:network])
    end

    it "returns empty array when no capabilities required" do
      expect(greeter_skill.required_capabilities).to eq([])
    end
  end

  describe ".tool_name" do
    it "derives snake_case name from class name" do
      stub_const("MyNamespace::ResearchSkill", Class.new(described_class))
      expect(MyNamespace::ResearchSkill.tool_name).to eq("research_skill")
    end

    it "handles single-word names" do
      stub_const("GreetSkill", Class.new(described_class))
      expect(GreetSkill.tool_name).to eq("greet_skill")
    end

    it "handles acronyms" do
      stub_const("WriteHTMLSkill", Class.new(described_class))
      expect(WriteHTMLSkill.tool_name).to eq("write_html_skill")
    end
  end

  describe ".runtime_contract" do
    it "collects structured output, feedback, capabilities, and nested tools in one object" do
      calculator_tool = Class.new(Igniter::Tool) do
        description "Calculate"
      end
      skill_class = Class.new(described_class) do
        requires_capability :network
        tools calculator_tool
        feedback_enabled true
        feedback_store :memory

        output_schema do
          field :answer, String
        end
      end

      contract = skill_class.runtime_contract

      expect(contract).to be_a(Igniter::AI::Skill::RuntimeContract)
      expect(contract.structured_output?).to be true
      expect(contract.feedback?).to be true
      expect(contract.required_capabilities).to eq([:network])
      expect(contract.tool_classes).to eq([calculator_tool])
      expect(contract.tool_names).to eq(["anonymous"])
      expect(contract.to_h).to include(
        structured_output: true,
        feedback_enabled: true,
        required_capabilities: [:network],
        tool_names: ["anonymous"],
        tool_count: 1
      )
    end

    it "reflects inherited skill semantics without sharing feedback store" do
      parent = Class.new(described_class) do
        requires_capability :network
        feedback_enabled true
        feedback_store :memory

        output_schema do
          field :summary, String
        end
      end
      child = Class.new(parent)

      contract = child.runtime_contract

      expect(contract.structured_output?).to be true
      expect(contract.feedback?).to be true
      expect(contract.required_capabilities).to eq([:network])
      expect(contract.feedback_store).to be_nil
    end
  end

  # ── Schema generation ──────────────────────────────────────────────────────

  describe ".to_schema" do
    subject(:schema) { greeter_skill.to_schema }

    it "returns intermediate format with name, description, parameters" do
      expect(schema).to include(:name, :description, :parameters)
    end

    it "includes required params in the required array" do
      expect(schema.dig(:parameters, "required")).to eq(["name"])
    end

    it "maps :boolean type to JSON Schema boolean" do
      formal = schema.dig(:parameters, "properties", "formal")
      expect(formal["type"]).to eq("boolean")
    end

    it "includes default values in parameter schema" do
      formal = schema.dig(:parameters, "properties", "formal")
      expect(formal["default"]).to eq(false)
    end

    context "with :anthropic provider" do
      subject(:schema) { greeter_skill.to_schema(:anthropic) }

      it "uses input_schema key" do
        expect(schema).to have_key(:input_schema)
        expect(schema).not_to have_key(:parameters)
      end

      it "includes name and description at top level" do
        expect(schema[:name]).to eq(greeter_skill.tool_name)
        expect(schema[:description]).to eq(greeter_skill.description)
      end
    end

    context "with :openai provider" do
      subject(:schema) { greeter_skill.to_schema(:openai) }

      it "wraps in function object" do
        expect(schema[:type]).to eq("function")
        expect(schema[:function]).to include(:name, :description, :parameters)
      end
    end

    it "generates identical schema format as a Tool (interchangeable)" do
      tool_klass = Class.new(Igniter::Tool) do
        description "Greet"
        param :name, type: :string, required: true, desc: "Name"
      end
      skill_klass = Class.new(described_class) do
        description "Greet"
        param :name, type: :string, required: true, desc: "Name"
      end
      expect(tool_klass.to_schema.keys).to eq(skill_klass.to_schema.keys)
    end
  end

  # ── Inheritance ────────────────────────────────────────────────────────────

  describe "inheritance" do
    let(:base_skill) do
      Class.new(described_class) do
        description "Base skill"
        param :x, type: :string, required: true, desc: "Base param"
        requires_capability :network
      end
    end

    let(:child_skill) { Class.new(base_skill) }

    it "propagates description to subclass" do
      expect(child_skill.description).to eq("Base skill")
    end

    it "propagates params to subclass" do
      expect(child_skill.tool_params.map { |p| p[:name] }).to eq([:x])
    end

    it "propagates capabilities to subclass" do
      expect(child_skill.required_capabilities).to eq([:network])
    end

    it "isolates child param additions from parent" do
      child_skill.param :y, type: :integer, desc: "Child param"
      expect(base_skill.tool_params.map { |p| p[:name] }).to eq([:x])
      expect(child_skill.tool_params.map { |p| p[:name] }).to eq(%i[x y])
    end

    it "also propagates LLM config (provider, model) from Skill parent" do
      base = Class.new(described_class) { provider :ollama; model "llama3" }
      child = Class.new(base)
      expect(child.provider).to eq(:ollama)
      expect(child.model).to eq("llama3")
    end
  end

  # ── Executor compatibility ─────────────────────────────────────────────────

  describe "#call" do
    it "executes skill logic" do
      expect(greeter_skill.new.call(name: "Alice")).to eq("Hey Alice!")
    end

    it "honours optional param defaults" do
      expect(greeter_skill.new.call(name: "Bob", formal: true)).to eq("Good day, Bob.")
    end
  end

  # ── Capability guard ───────────────────────────────────────────────────────

  describe "#call_with_capability_check!" do
    it "raises CapabilityError when required capability is missing" do
      instance = research_skill.new
      expect {
        instance.call_with_capability_check!(allowed_capabilities: [], topic: "AI")
      }.to raise_error(Igniter::Tool::CapabilityError, /network/)
    end

    it "executes call when all capabilities are present" do
      instance = research_skill.new
      result = instance.call_with_capability_check!(
        allowed_capabilities: [:network], topic: "Ruby"
      )
      expect(result).to match(/Ruby/)
    end

    it "raises the same CapabilityError via Skill::CapabilityError alias" do
      expect(Igniter::AI::Skill::CapabilityError).to equal(Igniter::Tool::CapabilityError)
    end
  end

  # ── ToolRegistry interop ───────────────────────────────────────────────────

  describe "ToolRegistry integration" do
    before { Igniter::AI::ToolRegistry.clear! }
    after  { Igniter::AI::ToolRegistry.clear! }

    it "registers a Skill alongside a Tool" do
      tool = Class.new(Igniter::Tool) { description "T" }
      skill = Class.new(described_class) { description "S" }
      stub_const("ATool", tool)
      stub_const("ASkill", skill)
      Igniter::AI::ToolRegistry.register(ATool, ASkill)
      expect(Igniter::AI::ToolRegistry.size).to eq(2)
    end

    it "filters by capabilities (tool and skill mixed)" do
      free_tool  = Class.new(Igniter::Tool) { description "Free" }
      net_skill  = Class.new(described_class) do
        description "Net"; requires_capability :network
      end
      stub_const("FreeTool", free_tool)
      stub_const("NetSkill", net_skill)
      Igniter::AI::ToolRegistry.register(FreeTool, NetSkill)

      expect(Igniter::AI::ToolRegistry.tools_for(capabilities: []).map(&:name)).to eq(["FreeTool"])
      expect(Igniter::AI::ToolRegistry.tools_for(capabilities: [:network]).map(&:name))
        .to contain_exactly("FreeTool", "NetSkill")
    end

    it "raises ArgumentError for a non-discoverable class" do
      expect {
        Igniter::AI::ToolRegistry.register(String)
      }.to raise_error(ArgumentError, /Igniter::Tool or Igniter::AI::Skill subclass/)
    end
  end

  # ── LLM tool loop detection ────────────────────────────────────────────────

  describe "LLM tool-loop detection (respond_to? duck type)" do
    it "responds to :tool_name" do
      expect(greeter_skill).to respond_to(:tool_name)
    end

    it "responds to :to_schema" do
      expect(greeter_skill).to respond_to(:to_schema)
    end

    it "responds to :required_capabilities" do
      expect(greeter_skill).to respond_to(:required_capabilities)
    end

    it "Skill and Tool are interchangeable in the tools DSL" do
      executor = Class.new(Igniter::AI::Executor) do
        tools(
          Class.new(Igniter::Tool) { description "T" },
          Class.new(Igniter::AI::Skill) { description "S" }
        )
      end
      expect(executor.tools.size).to eq(2)
    end
  end
end
