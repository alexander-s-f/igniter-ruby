# frozen_string_literal: true

require "spec_helper"
require "igniter/ai/agents"

RSpec.describe Igniter::AI::Agents::EvolutionAgent do
  let(:h) { ->(type, state, payload = {}) { described_class.handlers[type].call(state: state, payload: payload) } }

  def base_state
    {
      population: [], generation: 0, history: [],
      best_strategy: nil, fitness_fn: nil, llm: nil,
      population_size: 4, mutation_rate: 0.5, elite_fraction: 0.5
    }
  end

  let(:configs) do
    [
      { temperature: 0.7, max_tokens: 512 },
      { temperature: 0.3, max_tokens: 256 },
      { temperature: 1.0, max_tokens: 128 }
    ]
  end

  # Simple fitness: higher temperature = better score
  let(:fitness_fn) { ->(cfg) { cfg[:temperature].to_f * 10 } }

  # ── :seed ──────────────────────────────────────────────────────────────────
  describe "on :seed" do
    it "creates a Strategy per config" do
      result = h.call(:seed, base_state, strategies: configs)
      expect(result[:population].size).to eq(3)
      expect(result[:population]).to all(be_a(described_class::Strategy))
    end

    it "assigns generation 0 to all seeds" do
      result = h.call(:seed, base_state, strategies: configs)
      expect(result[:population].map(&:generation)).to all(eq(0))
    end

    it "resets generation counter and history" do
      state = base_state.merge(generation: 5, history: [:x])
      result = h.call(:seed, state, strategies: configs)
      expect(result[:generation]).to eq(0)
      expect(result[:history]).to be_empty
    end

    it "initialises fitness to nil" do
      result = h.call(:seed, base_state, strategies: configs)
      expect(result[:population].map(&:fitness)).to all(be_nil)
    end
  end

  # ── :evaluate_population ───────────────────────────────────────────────────
  describe "on :evaluate_population" do
    it "scores every strategy" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:evaluate_population, state, fitness_fn: fitness_fn)
      expect(result[:population].map(&:fitness)).to all(be_a(Numeric))
    end

    it "sets best_strategy to the highest scorer" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:evaluate_population, state, fitness_fn: fitness_fn)
      best   = result[:best_strategy]
      expect(best.config[:temperature]).to eq(1.0)
    end

    it "assigns 0.0 to strategies that raise" do
      bad_fn = ->(_cfg) { raise "boom" }
      state  = h.call(:seed, base_state, strategies: [{ x: 1 }])
      result = h.call(:evaluate_population, state, fitness_fn: bad_fn)
      expect(result[:population].first.fitness).to eq(0.0)
    end

    it "is a no-op when no fitness_fn provided" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:evaluate_population, state)
      expect(result[:population].map(&:fitness)).to all(be_nil)
    end
  end

  # ── :evolve ────────────────────────────────────────────────────────────────
  describe "on :evolve" do
    def evaluated_state
      state = h.call(:seed, base_state, strategies: configs)
      h.call(:evaluate_population, state, fitness_fn: fitness_fn)
    end

    it "increments the generation counter" do
      result = h.call(:evolve, evaluated_state)
      expect(result[:generation]).to eq(1)
    end

    it "appends a GenerationReport to history" do
      result = h.call(:evolve, evaluated_state)
      expect(result[:history].last).to be_a(described_class::GenerationReport)
    end

    it "keeps population_size strategies" do
      result = h.call(:evolve, evaluated_state)
      expect(result[:population].size).to eq(base_state[:population_size])
    end

    it "tracks parent_ids in children" do
      result   = h.call(:evolve, evaluated_state)
      children = result[:population].select { |s| s.generation == 1 }
      expect(children).not_to be_empty
      children.each { |c| expect(c.parent_ids).not_to be_empty }
    end

    it "is a no-op when population has no evaluated strategies" do
      state  = h.call(:seed, base_state, strategies: configs) # no evaluation
      result = h.call(:evolve, state)
      expect(result[:generation]).to eq(0)
    end
  end

  # ── :run_generation ────────────────────────────────────────────────────────
  describe "on :run_generation" do
    it "evaluates and evolves in one step" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:run_generation, state, fitness_fn: fitness_fn)
      expect(result[:generation]).to eq(1)
      expect(result[:history].size).to eq(1)
    end

    it "multiple generations improve or maintain best fitness" do
      state = h.call(:seed, base_state, strategies: configs)
      3.times { state = h.call(:run_generation, state, fitness_fn: fitness_fn) }
      expect(state[:generation]).to eq(3)
      expect(state[:best_strategy]).not_to be_nil
    end

    it "is a no-op when no fitness_fn provided" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:run_generation, state)
      expect(result[:generation]).to eq(0)
    end
  end

  # ── :mutate_strategy ───────────────────────────────────────────────────────
  describe "on :mutate_strategy" do
    it "adds a child to the population" do
      state  = h.call(:seed, base_state, strategies: configs)
      parent = state[:population].first
      result = h.call(:mutate_strategy, state, id: parent.id)
      expect(result[:population].size).to eq(configs.size + 1)
    end

    it "is a no-op for unknown id" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:mutate_strategy, state, id: "nonexistent")
      expect(result[:population].size).to eq(configs.size)
    end

    it "records parent_ids in the child" do
      state  = h.call(:seed, base_state, strategies: configs)
      parent = state[:population].first
      result = h.call(:mutate_strategy, state, id: parent.id)
      child  = result[:population].last
      expect(child.parent_ids).to include(parent.id)
    end
  end

  # ── sync queries ────────────────────────────────────────────────────────────
  describe "on :best" do
    it "returns nil before evaluation" do
      state = h.call(:seed, base_state, strategies: configs)
      expect(h.call(:best, state)).to be_nil
    end

    it "returns the best Strategy after evaluation" do
      state  = h.call(:seed, base_state, strategies: configs)
      state  = h.call(:evaluate_population, state, fitness_fn: fitness_fn)
      result = h.call(:best, state)
      expect(result).to be_a(described_class::Strategy)
      expect(result.fitness).not_to be_nil
    end
  end

  describe "on :population" do
    it "returns population array" do
      state  = h.call(:seed, base_state, strategies: configs)
      result = h.call(:population, state)
      expect(result).to be_an(Array)
    end
  end

  describe "on :history" do
    it "returns empty array before any evolution" do
      expect(h.call(:history, base_state)).to eq([])
    end

    it "returns GenerationReport entries after evolution" do
      state  = h.call(:seed, base_state, strategies: configs)
      state  = h.call(:run_generation, state, fitness_fn: fitness_fn)
      result = h.call(:history, state)
      expect(result.first).to be_a(described_class::GenerationReport)
    end
  end

  describe "on :generation" do
    it "starts at 0" do
      expect(h.call(:generation, base_state)).to eq(0)
    end
  end

  # ── GenerationReport correctness ───────────────────────────────────────────
  describe "GenerationReport" do
    it "reports best_fitness and mean_fitness" do
      state  = h.call(:seed, base_state, strategies: configs)
      state  = h.call(:run_generation, state, fitness_fn: fitness_fn)
      report = state[:history].last
      expect(report.best_fitness).to be >= report.mean_fitness
    end

    it "records the winning strategy id" do
      state  = h.call(:seed, base_state, strategies: configs)
      state  = h.call(:run_generation, state, fitness_fn: fitness_fn)
      report = state[:history].last
      expect(report.best_id).to be_a(String)
    end
  end

  # ── LLM mutation ───────────────────────────────────────────────────────────
  describe "LLM-assisted mutation" do
    let(:llm) { ->(strategy:, **) { strategy.merge(temperature: 0.9) } }

    it "delegates mutation to LLM callable" do
      state  = base_state.merge(llm: llm)
      state  = h.call(:seed, state, strategies: [{ temperature: 0.5 }])
      state  = h.call(:evaluate_population, state, fitness_fn: fitness_fn)
      result = h.call(:evolve, state)
      child  = result[:population].find { |s| s.generation == 1 }
      expect(child.config[:temperature]).to eq(0.9)
    end

    it "falls back to rule-based mutation when LLM raises" do
      bad_llm = ->(**) { raise "api error" }
      state   = base_state.merge(llm: bad_llm)
      state   = h.call(:seed, state, strategies: [{ temperature: 0.5, max_tokens: 100 }])
      state   = h.call(:evaluate_population, state, fitness_fn: fitness_fn)
      expect { h.call(:evolve, state) }.not_to raise_error
    end
  end

  # ── :configure ─────────────────────────────────────────────────────────────
  describe "on :configure" do
    it "updates population_size" do
      result = h.call(:configure, base_state, population_size: 10)
      expect(result[:population_size]).to eq(10)
    end

    it "updates mutation_rate" do
      result = h.call(:configure, base_state, mutation_rate: 0.1)
      expect(result[:mutation_rate]).to eq(0.1)
    end

    it "updates fitness_fn" do
      fn     = ->(_) { 42.0 }
      result = h.call(:configure, base_state, fitness_fn: fn)
      expect(result[:fitness_fn]).to eq(fn)
    end
  end

  # ── :reset ─────────────────────────────────────────────────────────────────
  describe "on :reset" do
    it "clears population, history, and best_strategy" do
      state  = h.call(:seed, base_state, strategies: configs)
      state  = h.call(:run_generation, state, fitness_fn: fitness_fn)
      result = h.call(:reset, state)
      expect(result[:population]).to be_empty
      expect(result[:history]).to be_empty
      expect(result[:best_strategy]).to be_nil
      expect(result[:generation]).to eq(0)
    end
  end
end
