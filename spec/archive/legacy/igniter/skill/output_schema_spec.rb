# frozen_string_literal: true

require "spec_helper"
require "igniter/ai"

RSpec.describe Igniter::AI::Skill::OutputSchema do
  let(:schema) do
    described_class.new do
      field :summary,    String
      field :confidence, Float
      field :sources,    Array
    end
  end

  # ── DSL ──────────────────────────────────────────────────────────────────────

  describe "#field" do
    it "records declared fields" do
      fields = schema.fields
      expect(fields.map(&:name)).to eq(%i[summary confidence sources])
    end

    it "records the Ruby type for each field" do
      f = schema.fields.find { |x| x.name == :summary }
      expect(f.type).to eq(String)
    end

    it "returns self for chaining" do
      s = described_class.new
      expect(s.field(:x, String)).to be(s)
    end
  end

  describe "#to_json_description" do
    it "produces a JSON-like schema string" do
      desc = schema.to_json_description
      expect(desc).to include('"summary": string')
      expect(desc).to include('"confidence": number')
      expect(desc).to include('"sources": array')
    end

    it "wraps output in curly braces" do
      expect(schema.to_json_description).to match(/\A\{.*\}\z/)
    end

    it "maps Integer to number" do
      s = described_class.new { field :count, Integer }
      expect(s.to_json_description).to include('"count": number')
    end

    it "maps Hash to object" do
      s = described_class.new { field :meta, Hash }
      expect(s.to_json_description).to include('"meta": object')
    end

    it "maps unknown types to string" do
      s = described_class.new { field :x, Symbol }
      expect(s.to_json_description).to include('"x": string')
    end
  end

  # ── #parse ───────────────────────────────────────────────────────────────────

  describe "#parse" do
    let(:valid_json) do
      '{"summary": "Nice doc", "confidence": 0.9, "sources": ["a", "b"]}'
    end

    it "returns a StructuredResult for valid JSON" do
      result = schema.parse(valid_json)
      expect(result).to be_a(Igniter::AI::Skill::StructuredResult)
    end

    it "exposes declared field readers on the result" do
      result = schema.parse(valid_json)
      expect(result.summary).to eq("Nice doc")
      expect(result.confidence).to eq(0.9)
      expect(result.sources).to eq(%w[a b])
    end

    it "extracts JSON from surrounding prose" do
      text = "Here is my answer:\n#{valid_json}\nThat's it."
      result = schema.parse(text)
      expect(result.summary).to eq("Nice doc")
    end

    it "raises ParseError when no JSON object is found" do
      expect { schema.parse("Just some plain text.") }
        .to raise_error(Igniter::AI::Skill::OutputSchema::ParseError, /No JSON object found/)
    end

    it "raises ParseError for malformed JSON" do
      expect { schema.parse("{not valid json}") }
        .to raise_error(Igniter::AI::Skill::OutputSchema::ParseError, /Invalid JSON/)
    end
  end
end

RSpec.describe Igniter::AI::Skill::StructuredResult do
  let(:fields) do
    [
      Igniter::AI::Skill::OutputSchema::Field.new(name: :title,  type: String),
      Igniter::AI::Skill::OutputSchema::Field.new(name: :score,  type: Float)
    ]
  end

  let(:data) { { "title" => "Hello", "score" => 0.75 } }
  let(:result) { described_class.new(fields, data) }

  it "provides reader methods for each field" do
    expect(result.title).to eq("Hello")
    expect(result.score).to eq(0.75)
  end

  describe "#to_h" do
    it "returns a symbol-keyed hash of all fields" do
      expect(result.to_h).to eq({ title: "Hello", score: 0.75 })
    end
  end

  describe "#to_json" do
    it "serializes to JSON" do
      parsed = JSON.parse(result.to_json)
      expect(parsed["title"]).to eq("Hello")
      expect(parsed["score"]).to eq(0.75)
    end
  end

  describe "#inspect" do
    it "includes class name and data" do
      expect(result.inspect).to match(/StructuredResult/)
      expect(result.inspect).to include("Hello")
    end
  end
end

RSpec.describe Igniter::AI::Skill do
  describe ".output_schema DSL" do
    let(:skill_class) do
      Class.new(described_class) do
        output_schema do
          field :answer, String
          field :score,  Float
        end

        def call(query:) = complete("Answer: #{query}")
      end
    end

    it "stores an OutputSchema instance" do
      expect(skill_class.output_schema).to be_a(Igniter::AI::Skill::OutputSchema)
    end

    it "exposes structured output through the runtime contract" do
      contract = skill_class.runtime_contract
      expect(contract.structured_output?).to be true
      expect(contract.to_h[:output_schema]).to include(
        type: "structured",
        fields: [hash_including(name: :answer, type: "String"), hash_including(name: :score, type: "Float")]
      )
    end

    it "propagates output_schema to subclasses" do
      child = Class.new(skill_class)
      expect(child.output_schema).to be_a(Igniter::AI::Skill::OutputSchema)
    end

    it "does not share the same instance across sibling classes" do
      sibling = Class.new(described_class)
      expect(sibling.output_schema).to be_nil
    end

    context "backward-compat: plain value (no block)" do
      let(:plain_executor) do
        Class.new(described_class) do
          output_schema "MySchemaV1"
          def call = nil
        end
      end

      it "stores the value via Executor metadata (no OutputSchema created)" do
        expect(plain_executor.output_schema).to eq("MySchemaV1")
        expect(plain_executor.output_schema).not_to be_a(Igniter::AI::Skill::OutputSchema)
      end
    end
  end

  describe "#complete with output_schema" do
    # Stub AI::Executor#complete (the parent) to return a fixed string,
    # letting Skill's override intercept and parse/forward it.
    # rubocop:disable Metrics/MethodLength
    def stub_llm_complete(instance, return_value)
      allow(Igniter::AI::Executor.instance_method(:complete)
              .bind(instance))
        .to receive(:call) { return_value }
    rescue TypeError
      # bind approach may not work in all Ruby versions; fall back to stub on instance
      allow(instance).to receive(:complete).and_wrap_original do |_original, prompt, **_kw|
        # Call Skill's override with the prompt but intercept super
        schema = instance.class.output_schema
        if schema.is_a?(Igniter::AI::Skill::OutputSchema)
          # rubocop:disable Lint/Void
          "#{prompt}\n\nRespond ONLY with valid JSON matching this schema: #{schema.to_json_description}"
          # rubocop:enable Lint/Void
        else
          prompt
        end
        schema.is_a?(Igniter::AI::Skill::OutputSchema) ? schema.parse(return_value) : return_value
      end
    end
    # rubocop:enable Metrics/MethodLength

    let(:skill_class_with_schema) do
      Class.new(described_class) do
        output_schema do
          field :answer, String
          field :score,  Float
        end
      end
    end

    let(:skill_class_without_schema) do
      Class.new(described_class)
    end

    it "returns a StructuredResult when output_schema is set" do
      instance = skill_class_with_schema.new
      allow_any_instance_of(Igniter::AI::Executor).to receive(:complete)
        .and_return('{"answer": "42", "score": 1.0}')

      result = instance.send(:complete, "test")
      expect(result).to be_a(Igniter::AI::Skill::StructuredResult)
      expect(result.answer).to eq("42")
      expect(result.score).to eq(1.0)
    end

    it "returns a plain String when no output_schema is set" do
      instance = skill_class_without_schema.new
      allow_any_instance_of(Igniter::AI::Executor).to receive(:complete)
        .and_return("plain text")

      result = instance.send(:complete, "test")
      expect(result).to eq("plain text")
    end

    it "injects JSON instruction into the prompt when output_schema is set" do
      received_prompt = nil
      instance = skill_class_with_schema.new

      allow_any_instance_of(Igniter::AI::Executor).to receive(:complete) do |_, prompt, **|
        received_prompt = prompt
        '{"answer": "yes", "score": 0.5}'
      end

      instance.send(:complete, "my question")
      expect(received_prompt).to include("my question")
      expect(received_prompt).to include("Respond ONLY with valid JSON")
    end

    it "passes the prompt through unchanged when no output_schema" do
      received_prompt = nil
      instance = skill_class_without_schema.new

      allow_any_instance_of(Igniter::AI::Executor).to receive(:complete) do |_, prompt, **|
        received_prompt = prompt
        "plain answer"
      end

      instance.send(:complete, "my question")
      expect(received_prompt).to eq("my question")
    end
  end
end
