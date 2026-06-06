# frozen_string_literal: true

require "spec_helper"
require "igniter/ai"

RSpec.describe "Igniter LLM Integration" do
  # ── Config ────────────────────────────────────────────────────────────────

  describe Igniter::AI::Config do
    subject(:config) { described_class.new }

    it "defaults to ollama provider" do
      expect(config.default_provider).to eq(:ollama)
    end

    it "provides ollama config" do
      expect(config.ollama.base_url).to eq("http://localhost:11434")
      expect(config.ollama.default_model).to eq("llama3.2")
    end

    it "raises on unknown provider" do
      expect { config.provider_config(:unknown) }.to raise_error(ArgumentError, /Unknown LLM provider/)
    end
  end

  # ── Context ───────────────────────────────────────────────────────────────

  describe Igniter::AI::Context do
    it "starts empty" do
      ctx = described_class.empty
      expect(ctx.empty?).to be true
    end

    it "initialises with a system prompt" do
      ctx = described_class.empty(system: "Be concise.")
      expect(ctx.messages.first).to eq({ role: :system, content: "Be concise." })
    end

    it "appends messages immutably" do
      ctx = described_class.empty
      ctx2 = ctx.append_user("Hello")
      expect(ctx.length).to eq(0)
      expect(ctx2.length).to eq(1)
      expect(ctx2.messages.first[:role]).to eq(:user)
    end

    it "serialises and restores via to_h / from_h" do
      ctx = described_class.empty(system: "sys")
                           .append_user("hi")
                           .append_assistant("hello")

      restored = described_class.from_h(ctx.to_h)
      expect(restored.length).to eq(ctx.length)
      expect(restored.messages.map { |m| m[:role] }).to eq(%i[system user assistant])
    end

    it "converts to_a with string roles for provider consumption" do
      ctx = described_class.empty(system: "sys").append_user("q")
      expect(ctx.to_a).to eq([
                               { "role" => "system", "content" => "sys" },
                               { "role" => "user", "content" => "q" }
                             ])
    end
  end

  # ── Ollama Provider ───────────────────────────────────────────────────────

  describe Igniter::AI::Providers::Ollama do
    subject(:provider) { described_class.new(base_url: "http://localhost:11434") }

    context "when Ollama is not available" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:request)
          .and_raise(Errno::ECONNREFUSED, "connection refused")
      end

      it "raises ProviderError on connection failure" do
        expect do
          provider.chat(messages: [{ role: "user", content: "hello" }], model: "llama3.2")
        end.to raise_error(Igniter::AI::ProviderError)
      end
    end

    context "with a stubbed successful response" do
      let(:response_body) do
        JSON.generate({
                        "model" => "llama3.2",
                        "message" => { "role" => "assistant", "content" => "Hello!" },
                        "eval_count" => 10,
                        "prompt_eval_count" => 5,
                        "done" => true
                      })
      end

      before do
        http_response = instance_double(Net::HTTPOK,
                                        is_a?: true,
                                        body: response_body)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
      end

      it "returns content from successful response" do
        result = provider.chat(
          messages: [{ role: "user", content: "Hi" }],
          model: "llama3.2"
        )
        expect(result[:content]).to eq("Hello!")
        expect(result[:role]).to eq(:assistant)
      end

      it "tracks token usage" do
        provider.chat(messages: [{ role: "user", content: "Hi" }], model: "llama3.2")
        expect(provider.last_usage[:total_tokens]).to eq(15)
        expect(provider.last_usage[:completion_tokens]).to eq(10)
      end

      it "provides single-turn complete shortcut" do
        result = provider.complete(prompt: "Hi", system: "Be brief.", model: "llama3.2")
        expect(result).to eq("Hello!")
      end
    end
  end

  # ── Anthropic Provider ────────────────────────────────────────────────────

  describe Igniter::AI::Providers::Anthropic do
    subject(:provider) { described_class.new(api_key: "test-key") }

    context "when API key is missing" do
      it "raises ConfigurationError" do
        p = described_class.new(api_key: nil)
        expect do
          p.chat(messages: [{ role: "user", content: "hi" }], model: "claude-sonnet-4-6")
        end.to raise_error(Igniter::AI::ConfigurationError, /API key not configured/)
      end
    end

    context "when Anthropic is not reachable" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:request)
          .and_raise(Errno::ECONNREFUSED, "connection refused")
      end

      it "raises ProviderError on connection failure" do
        expect do
          provider.chat(messages: [{ role: "user", content: "hello" }], model: "claude-sonnet-4-6")
        end.to raise_error(Igniter::AI::ProviderError, /Cannot connect/)
      end
    end

    context "with a stubbed successful response" do
      let(:response_body) do
        JSON.generate({
                        "id" => "msg_01",
                        "type" => "message",
                        "role" => "assistant",
                        "content" => [{ "type" => "text", "text" => "Hello from Claude!" }],
                        "usage" => { "input_tokens" => 8, "output_tokens" => 12 }
                      })
      end

      before do
        http_response = instance_double(Net::HTTPOK, body: response_body)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
      end

      it "returns content from the text block" do
        result = provider.chat(
          messages: [{ role: "user", content: "Hi" }],
          model: "claude-sonnet-4-6"
        )
        expect(result[:content]).to eq("Hello from Claude!")
        expect(result[:role]).to eq(:assistant)
        expect(result[:tool_calls]).to eq([])
      end

      it "tracks token usage" do
        provider.chat(messages: [{ role: "user", content: "Hi" }], model: "claude-sonnet-4-6")
        expect(provider.last_usage[:prompt_tokens]).to eq(8)
        expect(provider.last_usage[:completion_tokens]).to eq(12)
        expect(provider.last_usage[:total_tokens]).to eq(20)
      end

      it "extracts system message from messages array" do
        messages = [
          { role: "system", content: "Be concise." },
          { role: "user", content: "What is 2+2?" }
        ]
        # We verify it doesn't raise and processes correctly
        result = provider.chat(messages: messages, model: "claude-sonnet-4-6")
        expect(result[:content]).to eq("Hello from Claude!")
      end
    end

    context "with a tool_use response" do
      let(:response_body) do
        JSON.generate({
                        "role" => "assistant",
                        "content" => [
                          { "type" => "tool_use", "name" => "search", "input" => { "query" => "ruby" } }
                        ],
                        "usage" => { "input_tokens" => 5, "output_tokens" => 8 }
                      })
      end

      before do
        http_response = instance_double(Net::HTTPOK, body: response_body)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
      end

      it "parses tool_use blocks into tool_calls" do
        result = provider.chat(
          messages: [{ role: "user", content: "Search for ruby" }],
          model: "claude-sonnet-4-6"
        )
        expect(result[:tool_calls].length).to eq(1)
        expect(result[:tool_calls].first[:name]).to eq("search")
        expect(result[:tool_calls].first[:arguments]).to eq({ query: "ruby" })
      end
    end
  end

  # ── OpenAI Provider ────────────────────────────────────────────────────────

  describe Igniter::AI::Providers::OpenAI do
    subject(:provider) { described_class.new(api_key: "sk-test") }

    context "when API key is missing" do
      it "raises ConfigurationError" do
        p = described_class.new(api_key: nil)
        expect do
          p.chat(messages: [{ role: "user", content: "hi" }], model: "gpt-4o")
        end.to raise_error(Igniter::AI::ConfigurationError, /API key not configured/)
      end
    end

    context "when OpenAI is not reachable" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:request)
          .and_raise(Errno::ECONNREFUSED, "connection refused")
      end

      it "raises ProviderError on connection failure" do
        expect do
          provider.chat(messages: [{ role: "user", content: "hello" }], model: "gpt-4o")
        end.to raise_error(Igniter::AI::ProviderError, /Cannot connect/)
      end
    end

    context "with a stubbed successful response" do
      let(:response_body) do
        JSON.generate({
                        "id" => "chatcmpl-01",
                        "object" => "chat.completion",
                        "choices" => [
                          {
                            "index" => 0,
                            "message" => { "role" => "assistant", "content" => "Hello from GPT!" },
                            "finish_reason" => "stop"
                          }
                        ],
                        "usage" => { "prompt_tokens" => 6, "completion_tokens" => 9, "total_tokens" => 15 }
                      })
      end

      before do
        http_response = instance_double(Net::HTTPOK, body: response_body)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
      end

      it "returns content from choices[0].message" do
        result = provider.chat(
          messages: [{ role: "user", content: "Hi" }],
          model: "gpt-4o"
        )
        expect(result[:content]).to eq("Hello from GPT!")
        expect(result[:role]).to eq(:assistant)
        expect(result[:tool_calls]).to eq([])
      end

      it "tracks token usage" do
        provider.chat(messages: [{ role: "user", content: "Hi" }], model: "gpt-4o")
        expect(provider.last_usage[:prompt_tokens]).to eq(6)
        expect(provider.last_usage[:completion_tokens]).to eq(9)
        expect(provider.last_usage[:total_tokens]).to eq(15)
      end

      it "provides single-turn complete shortcut" do
        result = provider.complete(prompt: "Hi", system: "Be brief.", model: "gpt-4o")
        expect(result).to eq("Hello from GPT!")
      end
    end

    context "with a tool_calls response" do
      let(:response_body) do
        JSON.generate({
                        "choices" => [
                          {
                            "message" => {
                              "role" => "assistant",
                              "content" => nil,
                              "tool_calls" => [
                                {
                                  "type" => "function",
                                  "function" => {
                                    "name" => "get_weather",
                                    "arguments" => JSON.generate({ "location" => "Paris" })
                                  }
                                }
                              ]
                            },
                            "finish_reason" => "tool_calls"
                          }
                        ],
                        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 }
                      })
      end

      before do
        http_response = instance_double(Net::HTTPOK, body: response_body)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)
      end

      it "parses tool_calls from the message" do
        result = provider.chat(
          messages: [{ role: "user", content: "What's the weather in Paris?" }],
          model: "gpt-4o"
        )
        expect(result[:tool_calls].length).to eq(1)
        expect(result[:tool_calls].first[:name]).to eq("get_weather")
        expect(result[:tool_calls].first[:arguments]).to eq({ location: "Paris" })
      end
    end
  end

  # ── LLM Executor ──────────────────────────────────────────────────────────

  describe Igniter::AI::Executor do
    let(:response_body) do
      JSON.generate({
                      "message" => { "role" => "assistant", "content" => "The answer is 42." },
                      "eval_count" => 5,
                      "prompt_eval_count" => 3,
                      "done" => true
                    })
    end

    before do
      http_response = instance_double(Net::HTTPOK, body: response_body)
      allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(http_response)

      # Reset memoised provider instances
      Igniter::AI.instance_variable_set(:@provider_instances, nil)
    end

    let(:executor_class) do
      Class.new(described_class) do
        provider :ollama
        model "llama3.2"
        system_prompt "You are a helpful assistant."

        def call(question:)
          complete("Answer: #{question}")
        end
      end
    end

    it "has inherited class-level config" do
      expect(executor_class.provider).to eq(:ollama)
      expect(executor_class.model).to eq("llama3.2")
      expect(executor_class.system_prompt).to eq("You are a helpful assistant.")
    end

    it "subclasses inherit parent config" do
      subclass = Class.new(executor_class) do
        model "codellama"
      end
      expect(subclass.provider).to eq(:ollama)
      expect(subclass.model).to eq("codellama")
      expect(subclass.system_prompt).to eq("You are a helpful assistant.")
    end

    it "works as an Igniter compute node" do
      executor_class_ref = executor_class

      contract = Class.new(Igniter::Contract) do
        define do
          input :question
          compute :answer, depends_on: :question, call: executor_class_ref
          output :answer
        end
      end

      instance = contract.new(question: "What is the meaning of life?")
      instance.resolve_all

      expect(instance.success?).to be true
      expect(instance.result.answer).to eq("The answer is 42.")
    end

    it "is callable as a class (no instantiation needed in compute node)" do
      result = executor_class.call(question: "test")
      expect(result).to eq("The answer is 42.")
    end

    describe "context tracking" do
      it "tracks last_context after a complete call" do
        executor = executor_class.new
        executor.call(question: "something")
        expect(executor.last_context).to be_a(Igniter::AI::Context)
        expect(executor.last_context.length).to eq(3) # system + user + assistant
      end
    end
  end

  # ── Integration: Igniter.configure ───────────────────────────────────────

  describe "Igniter.configure" do
    it "yields the igniter module" do
      configured_store = nil
      Igniter.configure do |c|
        configured_store = c.execution_store
      end
      expect(configured_store).to be_a(Igniter::Runtime::Stores::MemoryStore)
    end
  end
end
