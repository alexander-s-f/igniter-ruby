# frozen_string_literal: true

require "igniter/ai"
require "igniter/core/tool"

RSpec.describe "Igniter::AI tool-use loop" do
  # ── Fixtures ──────────────────────────────────────────────────────────────────

  let(:calculator_tool) do
    Class.new(Igniter::Tool) do
      def self.name = "Calculator"
      description "Perform basic arithmetic"
      param :expression, type: :string, required: true, desc: "Math expression"
      # no required capabilities

      def call(expression:)
        result = eval(expression) # rubocop:disable Security/Eval
        { result: result, expression: expression }
      end
    end
  end

  let(:restricted_tool) do
    Class.new(Igniter::Tool) do
      def self.name = "SendEmail"
      description "Send an email"
      param :to, type: :string, required: true
      requires_capability :email_send

      def call(to:) = { sent: true, to: to }
    end
  end

  # Mock provider that returns pre-scripted responses
  let(:mock_provider) do
    Class.new do
      attr_reader :last_usage, :calls

      def initialize(responses)
        @responses = responses.dup
        @calls     = []
        @last_usage = { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 }.freeze
      end

      def chat(messages:, model:, tools: [], **_opts)
        @calls << { messages: messages.dup, tools: tools }
        response = @responses.shift
        raise "No more mock responses" unless response

        response
      end
    end
  end

  # Helper — build an executor class with a mock provider
  def build_executor(tool_classes: [], capabilities: [], max_iters: 10, &responses_block)
    responses = responses_block ? responses_block.call : []
    provider  = mock_provider.new(responses)

    Class.new(Igniter::AI::Executor) do
      tools(*tool_classes) unless tool_classes.empty?
      capabilities(*capabilities) unless capabilities.empty?
      max_tool_iterations max_iters

      define_method(:provider_instance) { provider }
      define_singleton_method(:provider) { :mock }
      define_singleton_method(:model)    { "mock-model" }

      def call(prompt:)
        complete(prompt)
      end
    end
  end

  # ── to_schema output ──────────────────────────────────────────────────────────

  describe "Tool.to_schema (intermediate)" do
    it "generates correct intermediate schema" do
      schema = calculator_tool.to_schema
      expect(schema[:name]).to eq("calculator")
      expect(schema[:parameters]["properties"]["expression"]["type"]).to eq("string")
      expect(schema[:parameters]["required"]).to eq(["expression"])
    end
  end

  # ── complete without tool classes → simple path ───────────────────────────────

  describe "#complete without Tool classes" do
    it "returns content directly without looping" do
      provider = mock_provider.new([
                                     { role: :assistant, content: "Hello!", tool_calls: [] }
                                   ])
      executor_class = Class.new(Igniter::AI::Executor) do
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end
      result = executor_class.new.send(:complete, "Hi")
      expect(result).to eq("Hello!")
      expect(provider.calls.size).to eq(1)
    end
  end

  # ── Tool-use loop ─────────────────────────────────────────────────────────────

  describe "#complete with Tool classes (auto-loop)" do
    it "calls the tool and returns final text" do
      provider_responses = [
        # First turn: LLM requests tool
        {
          role: :assistant,
          content: "",
          tool_calls: [{ id: "c1", name: "calculator", arguments: { expression: "2 + 2" } }]
        },
        # Second turn: LLM produces final text
        { role: :assistant, content: "The answer is 4.", tool_calls: [] }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools(Class.new(Igniter::Tool) do
          def self.name = "Calculator"
          description "Math"
          param :expression, type: :string, required: true
          def call(expression:) = { result: eval(expression) } # rubocop:disable Security/Eval
        end)

        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      result = executor_class.new.send(:complete, "What is 2+2?")
      expect(result).to eq("The answer is 4.")
      expect(provider.calls.size).to eq(2)
    end

    it "appends tool_results message after executing tool" do
      calc = Class.new(Igniter::Tool) do
        def self.name = "Calc"
        description "Math"
        param :expression, type: :string, required: true
        def call(expression:) = { result: eval(expression) } # rubocop:disable Security/Eval
      end

      provider_responses = [
        {
          role: :assistant,
          content: "",
          tool_calls: [{ id: "id1", name: "calc", arguments: { expression: "3 * 3" } }]
        },
        { role: :assistant, content: "9", tool_calls: [] }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools calc
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      executor_class.new.send(:complete, "What is 3*3?")

      # Second call's messages should contain the tool_results batch
      second_call_messages = provider.calls.last[:messages]
      tool_results_msg = second_call_messages.find { |m| m[:role] == :tool_results }
      expect(tool_results_msg).not_to be_nil
      expect(tool_results_msg[:results].first[:id]).to eq("id1")
      expect(tool_results_msg[:results].first[:content]).to include("9")
    end

    it "sends tool schemas in the first request" do
      calc = Class.new(Igniter::Tool) do
        def self.name = "Calculator"
        description "Math"
        param :x, type: :integer, required: true
        def call(x:) = x
      end

      provider = mock_provider.new([
                                     { role: :assistant, content: "done", tool_calls: [] }
                                   ])

      executor_class = Class.new(Igniter::AI::Executor) do
        tools calc
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      executor_class.new.send(:complete, "Hi")
      sent_tools = provider.calls.first[:tools]
      expect(sent_tools).not_to be_empty
      expect(sent_tools.first[:name]).to eq("calculator")
    end

    it "handles multiple tool calls in one turn" do
      calc = Class.new(Igniter::Tool) do
        def self.name = "Calculator"
        description "Math"
        param :expression, type: :string, required: true
        def call(expression:) = eval(expression).to_s # rubocop:disable Security/Eval
      end

      provider_responses = [
        {
          role: :assistant,
          content: "",
          tool_calls: [
            { id: "a1", name: "calculator", arguments: { expression: "1 + 1" } },
            { id: "a2", name: "calculator", arguments: { expression: "2 + 2" } }
          ]
        },
        { role: :assistant, content: "2 and 4", tool_calls: [] }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools calc
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      result = executor_class.new.send(:complete, "Calculate")
      expect(result).to eq("2 and 4")

      # Both results in the tool_results message
      second_msgs = provider.calls.last[:messages]
      results_msg = second_msgs.find { |m| m[:role] == :tool_results }
      expect(results_msg[:results].size).to eq(2)
    end
  end

  # ── ToolLoopError ─────────────────────────────────────────────────────────────

  describe "max_tool_iterations guard" do
    it "raises ToolLoopError when loop exceeds limit" do
      calc = Class.new(Igniter::Tool) do
        def self.name = "Inf"
        description "Infinite"
        param :x, type: :string, required: true
        def call(x:) = x
      end

      # Always return tool_calls → infinite loop
      infinite_response = {
        role: :assistant,
        content: "",
        tool_calls: [{ id: "x", name: "inf", arguments: { x: "loop" } }]
      }
      provider = mock_provider.new(Array.new(5, infinite_response))

      executor_class = Class.new(Igniter::AI::Executor) do
        tools calc
        max_tool_iterations 3
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      expect { executor_class.new.send(:complete, "loop") }
        .to raise_error(Igniter::AI::ToolLoopError, /max_tool_iterations.*3/)
    end
  end

  # ── Capability guard ──────────────────────────────────────────────────────────

  describe "capability guard during tool dispatch" do
    it "raises CapabilityError when tool requires missing capability" do
      restricted = Class.new(Igniter::Tool) do
        def self.name = "Restricted"
        description "Restricted tool"
        param :x, type: :string, required: true
        requires_capability :secret_cap
        def call(x:) = x
      end

      provider_responses = [
        {
          role: :assistant,
          content: "",
          tool_calls: [{ id: "r1", name: "restricted", arguments: { x: "test" } }]
        }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools restricted
        # declared_capabilities is empty — :secret_cap not included
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      expect { executor_class.new.send(:complete, "go") }
        .to raise_error(Igniter::Tool::CapabilityError, /secret_cap/)
    end

    it "succeeds when agent has the required capability" do
      guarded = Class.new(Igniter::Tool) do
        def self.name = "Guarded"
        description "Guarded tool"
        param :input, type: :string, required: true
        requires_capability :special_cap
        def call(**) = "ok"
      end

      provider_responses = [
        {
          role: :assistant,
          content: "",
          tool_calls: [{ id: "g1", name: "guarded", arguments: { input: "input" } }]
        },
        { role: :assistant, content: "done", tool_calls: [] }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools guarded
        capabilities :special_cap
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      expect { executor_class.new.send(:complete, "go") }.not_to raise_error
    end
  end

  # ── Unknown tool ──────────────────────────────────────────────────────────────

  describe "unknown tool name in response" do
    it "returns error message string as tool result (lets LLM recover)" do
      calc = Class.new(Igniter::Tool) do
        def self.name = "Calculator"
        description "Math"
        param :val, type: :string, required: true
        def call(val:) = val
      end

      provider_responses = [
        {
          role: :assistant,
          content: "",
          tool_calls: [{ id: "u1", name: "nonexistent_tool", arguments: { val: "y" } }]
        },
        { role: :assistant, content: "I see the tool is unavailable.", tool_calls: [] }
      ]
      provider = mock_provider.new(provider_responses)

      executor_class = Class.new(Igniter::AI::Executor) do
        tools calc
        define_method(:provider_instance) { provider }
        define_singleton_method(:provider) { :mock }
        define_singleton_method(:model)    { "mock-model" }
      end

      result = executor_class.new.send(:complete, "use nonexistent")
      expect(result).to eq("I see the tool is unavailable.")

      second_msgs = provider.calls.last[:messages]
      results_msg = second_msgs.find { |m| m[:role] == :tool_results }
      expect(results_msg[:results].first[:content]).to match(/Unknown tool/)
    end
  end

  # ── max_tool_iterations DSL ───────────────────────────────────────────────────

  describe "max_tool_iterations DSL" do
    it "defaults to 10" do
      klass = Class.new(Igniter::AI::Executor)
      expect(klass.max_tool_iterations).to eq(10)
    end

    it "is inherited" do
      parent = Class.new(Igniter::AI::Executor) { max_tool_iterations 5 }
      child  = Class.new(parent)
      expect(child.max_tool_iterations).to eq(5)
    end
  end

  # ── Provider failover chain ───────────────────────────────────────────────────

  describe "provider failover" do
    let(:success_response) { { content: "fallback worked", tool_calls: [] } }
    let(:usage)            { { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 }.freeze }

    # Provider that always raises ProviderError
    let(:failing_provider_class) do
      Class.new do
        attr_reader :last_usage

        def initialize = (@last_usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }.freeze)
        def chat(**) = raise Igniter::AI::ProviderError, "Connection refused"
      end
    end

    def build_failover_executor(primary_prov, fallback_providers, providers_map)
      Class.new(Igniter::AI::Executor) do
        provider primary_prov, fallback: fallback_providers
        model "primary-model", fallback: fallback_providers.map { |p| "#{p}-model" }

        define_method(:provider_instance) { providers_map[@last_provider] }
        define_singleton_method(:provider) { primary_prov }

        def call(prompt:) = complete(prompt)
      end
    end

    describe ".provider_chain" do
      it "returns [primary] when no fallback given" do
        klass = Class.new(Igniter::AI::Executor) { provider :anthropic }
        expect(klass.provider_chain).to eq(%i[anthropic])
      end

      it "includes fallback providers" do
        klass = Class.new(Igniter::AI::Executor) do
          provider :anthropic, fallback: %i[openai ollama]
        end
        expect(klass.provider_chain).to eq(%i[anthropic openai ollama])
      end

      it "is copied to subclasses" do
        parent = Class.new(Igniter::AI::Executor) { provider :anthropic, fallback: [:openai] }
        child  = Class.new(parent)
        expect(child.provider_chain).to eq(%i[anthropic openai])
      end

      it "child can override without mutating parent" do
        parent = Class.new(Igniter::AI::Executor) { provider :anthropic, fallback: [:openai] }
        child  = Class.new(parent) { provider :ollama }
        expect(parent.provider_chain).to eq(%i[anthropic openai])
        expect(child.provider_chain).to eq(%i[ollama])
      end
    end

    describe ".model_chain" do
      it "returns [primary_model] when no fallback given" do
        klass = Class.new(Igniter::AI::Executor) { model "claude-sonnet-4-6" }
        expect(klass.model_chain).to eq(["claude-sonnet-4-6"])
      end

      it "includes fallback models" do
        klass = Class.new(Igniter::AI::Executor) do
          model "claude-sonnet-4-6", fallback: ["gpt-4o", "llama3.2"]
        end
        expect(klass.model_chain).to eq(["claude-sonnet-4-6", "gpt-4o", "llama3.2"])
      end

      it "is copied to subclasses independently" do
        parent = Class.new(Igniter::AI::Executor) { model "m1", fallback: ["m2"] }
        child  = Class.new(parent) { model "m3" }
        expect(parent.model_chain).to eq(%w[m1 m2])
        expect(child.model_chain).to eq(%w[m3])
      end
    end

    describe "failover on ProviderError" do
      let(:failing) do
        Class.new do
          attr_reader :last_usage

          def initialize = (@last_usage = {}.freeze)
          def chat(**) = raise Igniter::AI::ProviderError, "down"
        end
      end

      let(:succeeds) do
        resp = success_response
        u    = usage
        inst = Class.new do
          attr_reader :last_usage

          def chat(**) = @resp
        end.new

        inst.instance_variable_set(:@resp, resp)
        inst.instance_variable_set(:@last_usage, u)
        inst
      end

      def build_two_provider_executor(failing_class, success_inst)
        providers = { anthropic: failing_class.new, openai: success_inst }
        Class.new(Igniter::AI::Executor) do
          provider :anthropic, fallback: [:openai]
          model "claude-sonnet-4-6", fallback: ["gpt-4o"]

          define_method(:provider_instance) { providers[@last_provider] }
          define_singleton_method(:provider) { :anthropic }

          def call(prompt:) = complete(prompt)
        end
      end

      it "returns the fallback provider's response" do
        klass    = build_two_provider_executor(failing, succeeds)
        result   = klass.call(prompt: "hello")
        expect(result).to eq("fallback worked")
      end

      it "sets last_provider to the successful provider" do
        klass    = build_two_provider_executor(failing, succeeds)
        instance = klass.new
        instance.call(prompt: "hello")
        expect(instance.last_provider).to eq(:openai)
      end

      it "sets last_model to the fallback model" do
        klass    = build_two_provider_executor(failing, succeeds)
        instance = klass.new
        instance.call(prompt: "hello")
        expect(instance.last_model).to eq("gpt-4o")
      end

      it "raises the last ProviderError when all providers fail" do
        both_failing = { anthropic: failing.new, openai: failing.new }
        klass = Class.new(Igniter::AI::Executor) do
          provider :anthropic, fallback: [:openai]
          define_method(:provider_instance) { both_failing[@last_provider] }
          define_singleton_method(:provider) { :anthropic }
          def call(prompt:) = complete(prompt)
        end
        expect { klass.call(prompt: "x") }.to raise_error(Igniter::AI::ProviderError)
      end

      it "does NOT catch ConfigurationError (missing API key is a config bug)" do
        config_error_provider = Class.new do
          attr_reader :last_usage

          def initialize = (@last_usage = {}.freeze)
          def chat(**) = raise Igniter::AI::ConfigurationError, "no api key"
        end

        providers = { anthropic: config_error_provider.new }
        klass = Class.new(Igniter::AI::Executor) do
          provider :anthropic
          define_method(:provider_instance) { providers[@last_provider] }
          define_singleton_method(:provider) { :anthropic }
          def call(prompt:) = complete(prompt)
        end
        expect { klass.call(prompt: "x") }.to raise_error(Igniter::AI::ConfigurationError)
      end
    end

    describe "call_history tracking" do
      it "records input and output after each complete call" do
        succeeds = Class.new do
          attr_reader :last_usage

          def initialize = (@last_usage = {}.freeze)
          def chat(**) = { content: "result", tool_calls: [] }
        end.new

        klass = Class.new(Igniter::AI::Executor) do
          provider :ollama
          define_method(:provider_instance) { succeeds }
          define_singleton_method(:provider) { :ollama }
          def call(prompt:) = complete(prompt)
        end
        instance = klass.new
        instance.call(prompt: "question")
        expect(instance.call_history).not_to be_nil
        expect(instance.call_history.last[:input]).to eq("question")
        expect(instance.call_history.last[:output]).to eq("result")
      end

      it "retains at most 20 entries" do
        success = Class.new do
          attr_reader :last_usage

          def initialize = (@last_usage = {}.freeze)
          def chat(**) = { content: "r#{@n = (@n || 0) + 1}", tool_calls: [] }
        end.new

        klass = Class.new(Igniter::AI::Executor) do
          provider :ollama
          define_method(:provider_instance) { success }
          define_singleton_method(:provider) { :ollama }
          def call(prompt:) = complete(prompt)
        end
        instance = klass.new
        25.times { |i| instance.call(prompt: "q#{i}") }
        expect(instance.call_history.size).to eq(20)
      end
    end
  end
end
