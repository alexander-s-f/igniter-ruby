# frozen_string_literal: true

require "igniter"
require "igniter/core/tool"

RSpec.describe Igniter::Tool do
  # ── Minimal tool fixture ─────────────────────────────────────────────────────

  let(:search_tool) do
    Class.new(described_class) do
      def self.name = "SearchWeb"
      description "Search the internet"
      param :query,       type: :string,  required: true,  desc: "Search query"
      param :max_results, type: :integer, default: 5,      desc: "Max results"
      requires_capability :web_access

      def call(query:, max_results: 5)
        [{ title: "Result", url: "https://example.com", snippet: query }]
      end
    end
  end

  # ── Class-level DSL ──────────────────────────────────────────────────────────

  describe ".description" do
    it "stores the description" do
      expect(search_tool.description).to eq("Search the internet")
    end
  end

  describe ".param" do
    it "records params in order" do
      names = search_tool.tool_params.map { |p| p[:name] }
      expect(names).to eq(%i[query max_results])
    end

    it "records required flag" do
      query = search_tool.tool_params.find { |p| p[:name] == :query }
      expect(query[:required]).to be true
    end

    it "records default value" do
      max = search_tool.tool_params.find { |p| p[:name] == :max_results }
      expect(max[:default]).to eq(5)
    end

    it "records description" do
      query = search_tool.tool_params.find { |p| p[:name] == :query }
      expect(query[:desc]).to eq("Search query")
    end
  end

  describe ".requires_capability" do
    it "stores required capabilities" do
      expect(search_tool.required_capabilities).to eq(%i[web_access])
    end

    it "accepts multiple capabilities" do
      klass = Class.new(described_class) do
        requires_capability :web_access, :external_api
      end
      expect(klass.required_capabilities).to contain_exactly(:web_access, :external_api)
    end
  end

  describe ".tool_name" do
    it "converts ClassName to snake_case" do
      klass = Class.new(described_class) { def self.name = "SearchWeb" }
      expect(klass.tool_name).to eq("search_web")
    end

    it "handles multi-word names" do
      klass = Class.new(described_class) { def self.name = "QueryDatabase" }
      expect(klass.tool_name).to eq("query_database")
    end

    it "handles trailing Tool suffix" do
      klass = Class.new(described_class) { def self.name = "WriteFileTool" }
      expect(klass.tool_name).to eq("write_file_tool")
    end

    it "strips module namespace" do
      klass = Class.new(described_class) { def self.name = "My::Namespace::WriteFile" }
      expect(klass.tool_name).to eq("write_file")
    end
  end

  # ── Schema generation ────────────────────────────────────────────────────────

  describe ".to_schema" do
    context "without provider (intermediate format)" do
      subject(:schema) { search_tool.to_schema }

      it "includes name" do
        expect(schema[:name]).to eq("search_web")
      end

      it "includes description" do
        expect(schema[:description]).to eq("Search the internet")
      end

      it "has :parameters key" do
        expect(schema).to have_key(:parameters)
      end

      it "marks required params" do
        expect(schema[:parameters]["required"]).to eq(["query"])
      end

      it "maps :string type to JSON string" do
        prop = schema[:parameters]["properties"]["query"]
        expect(prop["type"]).to eq("string")
      end

      it "maps :integer type to JSON integer" do
        prop = schema[:parameters]["properties"]["max_results"]
        expect(prop["type"]).to eq("integer")
      end

      it "includes default values in properties" do
        prop = schema[:parameters]["properties"]["max_results"]
        expect(prop["default"]).to eq(5)
      end

      it "includes param descriptions" do
        prop = schema[:parameters]["properties"]["query"]
        expect(prop["description"]).to eq("Search query")
      end
    end

    context "with :anthropic provider" do
      subject(:schema) { search_tool.to_schema(:anthropic) }

      it "has :input_schema key" do
        expect(schema).to have_key(:input_schema)
      end

      it "does not have :parameters key" do
        expect(schema).not_to have_key(:parameters)
      end
    end

    context "with :openai provider" do
      subject(:schema) { search_tool.to_schema(:openai) }

      it "has type: 'function'" do
        expect(schema[:type]).to eq("function")
      end

      it "nests under :function key" do
        expect(schema[:function][:name]).to eq("search_web")
        expect(schema[:function]).to have_key(:parameters)
      end
    end

    context "with no params" do
      let(:simple) do
        Class.new(described_class) do
          def self.name = "Noop"
          description "Does nothing"
          def call = "ok"
        end
      end

      it "produces an empty properties object" do
        expect(simple.to_schema[:parameters]["properties"]).to eq({})
      end

      it "has no required array" do
        expect(simple.to_schema[:parameters]).not_to have_key("required")
      end
    end

    it "maps all supported types correctly" do
      klass = Class.new(described_class) do
        def self.name = "TypedTool"
        param :a, type: :string
        param :b, type: :integer
        param :c, type: :float
        param :d, type: :boolean
        param :e, type: :array
        param :f, type: :object
      end
      props = klass.to_schema[:parameters]["properties"]
      expect(props["a"]["type"]).to eq("string")
      expect(props["b"]["type"]).to eq("integer")
      expect(props["c"]["type"]).to eq("number")
      expect(props["d"]["type"]).to eq("boolean")
      expect(props["e"]["type"]).to eq("array")
      expect(props["f"]["type"]).to eq("object")
    end
  end

  # ── Inheritance ──────────────────────────────────────────────────────────────

  describe "inheritance" do
    it "does not inherit parent params" do
      child = Class.new(search_tool)
      expect(child.tool_params).to be_empty
    end

    it "inherits description" do
      child = Class.new(search_tool)
      expect(child.description).to eq("Search the internet")
    end

    it "does not inherit required_capabilities" do
      child = Class.new(search_tool)
      expect(child.required_capabilities).to eq([])
    end
  end

  # ── Executor compatibility ───────────────────────────────────────────────────

  it "is a subclass of Igniter::Executor" do
    expect(described_class.superclass).to eq(Igniter::Executor)
  end

  it "can be called directly via .call (Executor protocol)" do
    result = search_tool.call(query: "hello")
    expect(result).to be_an(Array)
    expect(result.first[:snippet]).to eq("hello")
  end

  # ── Capability guard ─────────────────────────────────────────────────────────

  describe "#call_with_capability_check!" do
    it "calls the tool when capabilities are satisfied" do
      result = search_tool.new.call_with_capability_check!(
        allowed_capabilities: [:web_access],
        query: "test"
      )
      expect(result).to be_an(Array)
    end

    it "raises CapabilityError when a required capability is missing" do
      expect {
        search_tool.new.call_with_capability_check!(
          allowed_capabilities: [],
          query: "test"
        )
      }.to raise_error(Igniter::Tool::CapabilityError, /web_access/)
    end

    it "includes missing capabilities in the error message" do
      expect {
        search_tool.new.call_with_capability_check!(
          allowed_capabilities: [:filesystem_read],
          query: "test"
        )
      }.to raise_error(Igniter::Tool::CapabilityError, /\[:web_access\]/)
    end

    it "passes for tools with no required capabilities" do
      no_cap_tool = Class.new(described_class) do
        def call(x:) = x * 2
      end
      expect(no_cap_tool.new.call_with_capability_check!(allowed_capabilities: [], x: 3)).to eq(6)
    end
  end
end
