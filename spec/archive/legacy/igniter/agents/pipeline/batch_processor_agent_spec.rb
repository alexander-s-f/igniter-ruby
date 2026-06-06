# frozen_string_literal: true

require "spec_helper"
require "igniter/agents"

RSpec.describe Igniter::Agents::BatchProcessorAgent do
  let(:callable) { ->(item:) { item * 2 } }
  let(:failing_callable) { ->(item:) { raise "oops" if item == :bad } }

  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  def state_with(items, c = callable)
    jobs = items.map { |i| { item: i, callable: c } }
    described_class.default_state.merge(queue: jobs)
  end

  describe "on :enqueue" do
    it "adds jobs to the queue" do
      result = call_handler(:enqueue,
        payload: { items: [1, 2, 3], callable: callable })
      expect(result[:queue].size).to eq(3)
    end

    it "preserves existing queue items" do
      state  = state_with([10])
      result = call_handler(:enqueue,
        state:   state,
        payload: { items: [20, 30], callable: callable })
      expect(result[:queue].size).to eq(3)
    end

    it "raises ArgumentError when callable is absent" do
      expect do
        call_handler(:enqueue, payload: { items: [1] })
      end.to raise_error(ArgumentError, /callable/)
    end

    it "uses state callable when payload omits one" do
      state  = described_class.default_state.merge(callable: callable)
      result = call_handler(:enqueue, state: state, payload: { items: [1, 2] })
      expect(result[:queue].size).to eq(2)
    end
  end

  describe "on :process_next" do
    it "processes up to batch_size items" do
      state  = state_with([1, 2, 3, 4, 5])
      result = call_handler(:process_next, state: state, payload: { batch_size: 3 })
      expect(result[:processed]).to eq(3)
      expect(result[:queue].size).to eq(2)
    end

    it "increments :processed counter" do
      state  = state_with([1, 2])
      result = call_handler(:process_next, state: state, payload: { batch_size: 10 })
      expect(result[:processed]).to eq(2)
    end

    it "increments :failed counter and records errors" do
      state  = state_with([:bad, :ok, :bad], failing_callable)
      result = call_handler(:process_next, state: state, payload: { batch_size: 3 })
      expect(result[:failed]).to eq(2)
      expect(result[:errors].size).to eq(2)
    end

    it "uses state batch_size when payload omits it" do
      state  = state_with([1, 2, 3, 4]).merge(batch_size: 2)
      result = call_handler(:process_next, state: state, payload: {})
      expect(result[:processed]).to eq(2)
    end
  end

  describe "on :drain" do
    it "processes all items synchronously" do
      state  = state_with([1, 2, 3, 4, 5])
      result = call_handler(:drain, state: state, payload: { batch_size: 2 })
      expect(result[:processed]).to eq(5)
      expect(result[:queue]).to be_empty
    end

    it "accumulates failures across batches" do
      state  = state_with([:bad, :ok, :bad, :ok], failing_callable)
      result = call_handler(:drain, state: state, payload: { batch_size: 2 })
      expect(result[:failed]).to eq(2)
      expect(result[:processed]).to eq(2)
    end
  end

  describe "on :status" do
    it "returns a Status struct" do
      state  = state_with([1, 2, 3]).merge(processed: 7, failed: 1)
      result = call_handler(:status, state: state)
      expect(result).to be_a(described_class::Status)
      expect(result.queue_size).to eq(3)
      expect(result.processed).to eq(7)
      expect(result.failed).to eq(1)
    end
  end

  describe "on :errors" do
    it "returns the error log array" do
      state  = described_class.default_state.merge(
        errors: [{ item: :bad, error: "oops" }]
      )
      result = call_handler(:errors, state: state)
      expect(result.first[:item]).to eq(:bad)
    end
  end

  describe "on :reset_stats" do
    it "resets processed, failed, and errors" do
      state  = described_class.default_state.merge(
        processed: 10, failed: 2, errors: [{ item: :x, error: "e" }]
      )
      result = call_handler(:reset_stats, state: state)
      expect(result[:processed]).to eq(0)
      expect(result[:failed]).to eq(0)
      expect(result[:errors]).to be_empty
    end

    it "preserves the queue" do
      state  = state_with([1, 2]).merge(processed: 5)
      result = call_handler(:reset_stats, state: state)
      expect(result[:queue].size).to eq(2)
    end
  end

  describe "on :configure" do
    it "updates batch_size" do
      result = call_handler(:configure, payload: { batch_size: 25 })
      expect(result[:batch_size]).to eq(25)
    end

    it "updates callable" do
      new_callable = ->(item:) { item }
      result = call_handler(:configure, payload: { callable: new_callable })
      expect(result[:callable]).to equal(new_callable)
    end
  end
end
