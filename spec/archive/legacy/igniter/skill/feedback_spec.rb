# frozen_string_literal: true

require "spec_helper"
require "igniter/ai"

RSpec.describe Igniter::AI::Skill::FeedbackEntry do
  let(:entry) do
    described_class.new(
      input: "what is Ruby?",
      output: "Ruby is a language",
      rating: :good,
      notes: "Very clear",
      timestamp: Time.now
    )
  end

  it "exposes all fields" do
    expect(entry.input).to eq("what is Ruby?")
    expect(entry.output).to eq("Ruby is a language")
    expect(entry.rating).to eq(:good)
    expect(entry.notes).to eq("Very clear")
    expect(entry.timestamp).to be_a(Time)
  end

  it "is frozen (immutable)" do
    expect(entry).to be_frozen
  end
end

RSpec.describe Igniter::AI::Skill::FeedbackStore::Memory do
  subject(:store) { described_class.new }

  let(:good_entry) do
    Igniter::AI::Skill::FeedbackEntry.new(
      input: "q", output: "a", rating: :good, notes: "nice", timestamp: Time.now
    )
  end

  let(:bad_entry) do
    Igniter::AI::Skill::FeedbackEntry.new(
      input: "q2", output: "a2", rating: :bad, notes: "wrong", timestamp: Time.now
    )
  end

  describe "#store and #all" do
    it "stores entries and retrieves them" do
      store.store(good_entry)
      expect(store.all).to include(good_entry)
    end

    it "returns a dup so callers can't modify internal state" do
      store.store(good_entry)
      store.all << bad_entry
      expect(store.size).to eq(1)
    end
  end

  describe "#size and #empty?" do
    it "is empty initially" do
      expect(store.empty?).to be true
      expect(store.size).to eq(0)
    end

    it "updates after storing" do
      store.store(good_entry)
      expect(store.size).to eq(1)
      expect(store.empty?).to be false
    end
  end

  describe "#by_rating" do
    before do
      store.store(good_entry)
      store.store(bad_entry)
    end

    it "filters by :good" do
      expect(store.by_rating(:good)).to eq([good_entry])
    end

    it "filters by :bad" do
      expect(store.by_rating(:bad)).to eq([bad_entry])
    end

    it "returns empty array for a rating with no entries" do
      expect(store.by_rating(:neutral)).to eq([])
    end
  end

  describe "#clear" do
    it "removes all entries" do
      store.store(good_entry)
      store.clear
      expect(store.empty?).to be true
    end

    it "returns self" do
      expect(store.clear).to be(store)
    end
  end

  describe "MAX_SIZE cap" do
    it "drops oldest entries when exceeding MAX_SIZE" do
      (described_class::MAX_SIZE + 5).times do |i|
        store.store(Igniter::AI::Skill::FeedbackEntry.new(
                      input: "q#{i}", output: "a#{i}", rating: :good, timestamp: Time.now
                    ))
      end
      expect(store.size).to eq(described_class::MAX_SIZE)
    end
  end

  describe "thread safety" do
    it "handles concurrent stores without data loss" do
      threads = 20.times.map do |i|
        Thread.new do
          store.store(Igniter::AI::Skill::FeedbackEntry.new(
                        input: "q#{i}", output: "a#{i}", rating: :good, timestamp: Time.now
                      ))
        end
      end
      threads.each(&:join)
      expect(store.size).to eq(20)
    end
  end
end

RSpec.describe Igniter::AI::Skill::FeedbackRefiner do
  let(:mock_provider) do
    Class.new do
      attr_reader :last_usage, :received_messages, :received_model

      def initialize
        @last_usage = { prompt_tokens: 5, completion_tokens: 10, total_tokens: 15 }.freeze
        @received_messages = nil
        @received_model    = nil
      end

      def chat(messages:, model:, **) = (@received_messages = messages

                                         @received_model = model
                                         { content: "improved prompt", tool_calls: [] })
    end.new
  end

  subject(:refiner) { described_class.new(mock_provider, "my-model") }

  let(:good_entry) do
    Igniter::AI::Skill::FeedbackEntry.new(
      input: "q", output: "a", rating: :good, notes: "Very helpful", timestamp: Time.now
    )
  end

  let(:bad_entry) do
    Igniter::AI::Skill::FeedbackEntry.new(
      input: "q", output: "b", rating: :bad, notes: "Too verbose", timestamp: Time.now
    )
  end

  describe "#refine" do
    it "returns the current prompt unchanged when no entries" do
      expect(refiner.refine("original", [])).to eq("original")
    end

    it "returns the current prompt when all entries have no notes" do
      no_notes = Igniter::AI::Skill::FeedbackEntry.new(
        input: "q", output: "a", rating: :bad, notes: nil, timestamp: Time.now
      )
      expect(refiner.refine("original", [no_notes])).to eq("original")
    end

    it "calls the provider with the correct model" do
      refiner.refine("original", [bad_entry])
      expect(mock_provider.received_model).to eq("my-model")
    end

    it "includes good feedback in the prompt" do
      refiner.refine("original", [good_entry])
      content = mock_provider.received_messages.last[:content]
      expect(content).to include("Very helpful")
    end

    it "includes bad feedback in the prompt" do
      refiner.refine("original", [bad_entry])
      content = mock_provider.received_messages.last[:content]
      expect(content).to include("Too verbose")
    end

    it "includes the current prompt in the message" do
      refiner.refine("Be concise.", [bad_entry])
      content = mock_provider.received_messages.last[:content]
      expect(content).to include("Be concise.")
    end

    it "returns the provider's response content" do
      expect(refiner.refine("original", [bad_entry])).to eq("improved prompt")
    end
  end
end

RSpec.describe Igniter::AI::Skill do
  describe "feedback DSL" do
    let(:skill_class) do
      Class.new(described_class) do
        feedback_enabled true
        feedback_store   :memory
        def call(prompt:) = complete(prompt)
      end
    end

    describe ".feedback_enabled" do
      it "defaults to false" do
        expect(Class.new(described_class).feedback_enabled).to be false
      end

      it "stores the value" do
        expect(skill_class.feedback_enabled).to be true
      end

      it "is propagated to subclasses" do
        child = Class.new(skill_class)
        expect(child.feedback_enabled).to be true
      end

      it "is reflected in the runtime contract" do
        expect(skill_class.runtime_contract.feedback?).to be true
      end
    end

    describe ".feedback_store :memory" do
      it "creates a FeedbackStore::Memory instance" do
        expect(skill_class.feedback_store).to be_a(Igniter::AI::Skill::FeedbackStore::Memory)
      end

      it "is NOT shared with subclasses (each class gets nil)" do
        child = Class.new(skill_class)
        expect(child.feedback_store).to be_nil
      end

      it "accepts a custom store object" do
        custom = double("store")
        klass  = Class.new(described_class) { feedback_store(custom) }
        expect(klass.feedback_store).to be(custom)
      end

      it "is reflected in the runtime contract" do
        contract = skill_class.runtime_contract
        expect(contract.feedback_store).to be_a(Igniter::AI::Skill::FeedbackStore::Memory)
        expect(contract.to_h[:feedback_store]).to include(:class_name, :size)
      end
    end
  end

  describe "#feedback" do
    let(:store) { Igniter::AI::Skill::FeedbackStore::Memory.new }

    let(:skill_class) do
      s = store
      klass = Class.new(described_class) do
        feedback_enabled true
        define_method(:feedback_store_override) { s }

        class << self
          attr_reader :feedback_store
        end
      end
      klass.instance_variable_set(:@feedback_store, store)
      klass
    end

    let(:instance) { skill_class.new }

    it "stores a FeedbackEntry in the store" do
      instance.feedback("my output", rating: :good, notes: "great")
      expect(store.size).to eq(1)
      expect(store.all.first.rating).to eq(:good)
      expect(store.all.first.notes).to eq("great")
    end

    it "records the string version of the output" do
      instance.feedback("my output", rating: :bad)
      expect(store.all.first.output).to eq("my output")
    end

    it "returns self for chaining" do
      expect(instance.feedback("x", rating: :good)).to be(instance)
    end

    it "is a no-op when feedback_enabled is false" do
      klass = Class.new(described_class) do
        feedback_enabled false
        feedback_store :memory
      end
      klass.new.feedback("x", rating: :bad)
      expect(klass.feedback_store.size).to eq(0)
    end

    it "is a no-op when no store is configured" do
      klass = Class.new(described_class) { feedback_enabled true }
      expect { klass.new.feedback("x", rating: :good) }.not_to raise_error
    end
  end

  describe "#refine_system_prompt" do
    it "raises Igniter::Error when no store is configured" do
      klass = Class.new(described_class)
      expect { klass.new.refine_system_prompt }
        .to raise_error(Igniter::Error, /No feedback_store configured/)
    end

    it "delegates to FeedbackRefiner with the provider and model" do
      mock_provider_obj = double("provider", last_usage: {}.freeze,
                                             chat: { content: "better prompt", tool_calls: [] })
      store = Igniter::AI::Skill::FeedbackStore::Memory.new
      store.store(Igniter::AI::Skill::FeedbackEntry.new(
                    input: "q", output: "a", rating: :bad, notes: "too long", timestamp: Time.now
                  ))

      klass = Class.new(described_class) do
        system_prompt "Be helpful."
        feedback_store :memory
      end
      klass.instance_variable_set(:@feedback_store, store)

      instance = klass.new
      allow(instance).to receive(:provider_instance).and_return(mock_provider_obj)
      allow(instance).to receive(:current_model).and_return("test-model")

      result = instance.refine_system_prompt
      expect(result).to eq("better prompt")
    end
  end
end
