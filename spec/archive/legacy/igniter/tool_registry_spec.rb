# frozen_string_literal: true

require "igniter"
require "igniter/ai"

RSpec.describe Igniter::AI::ToolRegistry do
  # Tool fixtures
  let(:search_tool) do
    Class.new(Igniter::Tool) do
      def self.name = "SearchWeb"
      description "Search the internet"
      param :query, type: :string, required: true
      requires_capability :web_access
      def call(query:) = [{ title: "Result", url: "https://example.com" }]
    end
  end

  let(:write_tool) do
    Class.new(Igniter::Tool) do
      def self.name = "WriteFile"
      description "Write a file"
      param :path, type: :string, required: true
      param :content, type: :string, required: true
      requires_capability :filesystem_write
      def call(path:, content:) = { written: true }
    end
  end

  let(:free_tool) do
    Class.new(Igniter::Tool) do
      def self.name = "Echo"
      description "Echo input"
      param :text, type: :string, required: true
      # no required capabilities
      def call(text:) = text
    end
  end

  after { described_class.clear! }

  # ── Registration ─────────────────────────────────────────────────────────────

  describe ".register" do
    it "registers a single tool" do
      described_class.register(search_tool)
      expect(described_class.all).to include(search_tool)
    end

    it "registers multiple tools at once" do
      described_class.register(search_tool, write_tool)
      expect(described_class.all).to include(search_tool, write_tool)
    end

    it "returns self for chaining" do
      expect(described_class.register(search_tool)).to be(described_class)
    end

    it "raises ArgumentError for non-Tool classes" do
      expect { described_class.register(String) }
        .to raise_error(ArgumentError, /must be an Igniter::Tool or Igniter::AI::Skill subclass/)
    end

    it "raises ArgumentError for plain objects" do
      expect { described_class.register("not a class") }
        .to raise_error(ArgumentError)
    end
  end

  # ── Lookup ───────────────────────────────────────────────────────────────────

  describe ".find" do
    before { described_class.register(search_tool) }

    it "returns the tool class by snake_case name" do
      expect(described_class.find("search_web")).to be(search_tool)
    end

    it "returns nil for unknown names" do
      expect(described_class.find("does_not_exist")).to be_nil
    end
  end

  # ── All tools ────────────────────────────────────────────────────────────────

  describe ".all" do
    it "returns an empty array when nothing is registered" do
      expect(described_class.all).to eq([])
    end

    it "returns all registered tool classes" do
      described_class.register(search_tool, write_tool)
      expect(described_class.all).to contain_exactly(search_tool, write_tool)
    end
  end

  describe ".size and .empty?" do
    it "reports 0 and empty? true initially" do
      expect(described_class.size).to eq(0)
      expect(described_class.empty?).to be true
    end

    it "updates after registration" do
      described_class.register(search_tool)
      expect(described_class.size).to eq(1)
      expect(described_class.empty?).to be false
    end
  end

  # ── Capability filtering ─────────────────────────────────────────────────────

  describe ".tools_for" do
    before { described_class.register(search_tool, write_tool, free_tool) }

    it "returns tools whose caps are all satisfied" do
      result = described_class.tools_for(capabilities: [:web_access])
      expect(result).to include(search_tool, free_tool)
      expect(result).not_to include(write_tool)
    end

    it "includes tools with no required capabilities unconditionally" do
      result = described_class.tools_for(capabilities: [])
      expect(result).to include(free_tool)
      expect(result).not_to include(search_tool, write_tool)
    end

    it "returns all non-restricted tools when all caps are provided" do
      result = described_class.tools_for(capabilities: %i[web_access filesystem_write])
      expect(result).to contain_exactly(search_tool, write_tool, free_tool)
    end
  end

  # ── Schema generation ────────────────────────────────────────────────────────

  describe ".schemas" do
    before { described_class.register(search_tool, free_tool) }

    it "returns intermediate schemas by default" do
      schemas = described_class.schemas
      expect(schemas).to all(have_key(:name))
      expect(schemas).to all(have_key(:parameters))
    end

    it "returns Anthropic schemas" do
      schemas = described_class.schemas(:anthropic)
      expect(schemas).to all(have_key(:input_schema))
    end

    it "returns OpenAI schemas" do
      schemas = described_class.schemas(:openai)
      expect(schemas).to all(have_key(:type))
      expect(schemas.map { |s| s[:type] }).to all(eq("function"))
    end

    it "filters by capabilities when provided" do
      described_class.register(write_tool)
      schemas = described_class.schemas(capabilities: [:web_access])
      names = schemas.map { |s| s[:name] }
      expect(names).to include("search_web", "echo")
      expect(names).not_to include("write_file")
    end
  end

  # ── clear! ───────────────────────────────────────────────────────────────────

  describe ".clear!" do
    it "removes all registrations" do
      described_class.register(search_tool)
      described_class.clear!
      expect(described_class.all).to eq([])
    end

    it "returns self" do
      expect(described_class.clear!).to be(described_class)
    end
  end

  # ── Scope hierarchy ──────────────────────────────────────────────────────────

  describe "scope support" do
    let(:bundled_tool) do
      Class.new(Igniter::Tool) do
        def self.name = "BundledWeather"
        description "Bundled weather tool"
        param :city, type: :string, required: true
        def call(**) = { temp: 20 }
      end
    end

    let(:managed_tool) do
      Class.new(Igniter::Tool) do
        def self.name = "ManagedTranslate"
        description "Managed translation tool"
        param :text, type: :string, required: true
        def call(text:) = text
      end
    end

    describe ".register with scope:" do
      it "accepts scope: :bundled" do
        described_class.register(bundled_tool, scope: :bundled)
        expect(described_class.all).to include(bundled_tool)
      end

      it "accepts scope: :managed" do
        described_class.register(managed_tool, scope: :managed)
        expect(described_class.all).to include(managed_tool)
      end

      it "defaults to scope: :workspace when no scope given" do
        described_class.register(free_tool)
        expect(described_class.all(scope: :workspace)).to include(free_tool)
      end

      it "raises ArgumentError for an invalid scope" do
        expect { described_class.register(free_tool, scope: :unknown) }
          .to raise_error(ArgumentError, /Invalid scope/)
      end
    end

    describe ".all with scope:" do
      before do
        described_class.register(bundled_tool, scope: :bundled)
        described_class.register(managed_tool, scope: :managed)
        described_class.register(free_tool,    scope: :workspace)
      end

      it "returns all tools when no scope given (backward compat)" do
        expect(described_class.all).to contain_exactly(bundled_tool, managed_tool, free_tool)
      end

      it "returns only bundled tools with scope: :bundled" do
        expect(described_class.all(scope: :bundled)).to contain_exactly(bundled_tool)
      end

      it "returns only managed tools with scope: :managed" do
        expect(described_class.all(scope: :managed)).to contain_exactly(managed_tool)
      end

      it "returns only workspace tools with scope: :workspace" do
        expect(described_class.all(scope: :workspace)).to contain_exactly(free_tool)
      end

      it "returns empty array for a scope with no registrations" do
        described_class.clear!
        described_class.register(free_tool, scope: :workspace)
        expect(described_class.all(scope: :bundled)).to eq([])
      end
    end

    describe ".find regardless of scope" do
      it "finds a bundled tool by name" do
        described_class.register(bundled_tool, scope: :bundled)
        expect(described_class.find("bundled_weather")).to be(bundled_tool)
      end

      it "finds a workspace tool by name" do
        described_class.register(free_tool, scope: :workspace)
        expect(described_class.find("echo")).to be(free_tool)
      end
    end

    describe ".size and .empty? count across all scopes" do
      it "counts entries from all scopes" do
        described_class.register(bundled_tool, scope: :bundled)
        described_class.register(free_tool,    scope: :workspace)
        expect(described_class.size).to eq(2)
      end

      it "is empty? when nothing registered regardless of scope" do
        expect(described_class.empty?).to be true
      end
    end

    describe ".tools_for with scope:" do
      before do
        described_class.register(search_tool, scope: :bundled)
        described_class.register(free_tool,   scope: :workspace)
      end

      it "filters by capability across all scopes when no scope given" do
        result = described_class.tools_for(capabilities: [:web_access])
        expect(result).to include(search_tool, free_tool)
      end

      it "filters by capability within a specific scope" do
        result = described_class.tools_for(capabilities: [:web_access], scope: :bundled)
        expect(result).to include(search_tool)
        expect(result).not_to include(free_tool)
      end
    end

    describe ".schemas with scope:" do
      before do
        described_class.register(bundled_tool, scope: :bundled)
        described_class.register(free_tool,    scope: :workspace)
      end

      it "generates schemas for all scopes when no scope given" do
        names = described_class.schemas.map { |s| s[:name] }
        expect(names).to include("bundled_weather", "echo")
      end

      it "generates schemas for the given scope only" do
        names = described_class.schemas(scope: :bundled).map { |s| s[:name] }
        expect(names).to contain_exactly("bundled_weather")
      end
    end
  end
end
