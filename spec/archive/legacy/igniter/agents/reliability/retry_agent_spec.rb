# frozen_string_literal: true

require "spec_helper"
require "igniter/agents"

RSpec.describe Igniter::Agents::RetryAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  describe "on :with_retry — success on first attempt" do
    it "returns state with no dead letter when callable succeeds" do
      callable = ->(**) { :ok }
      result   = call_handler(:with_retry,
        payload: { callable: callable, args: {}, max_retries: 2,
                   backoff: :immediate, base_delay: 0 })
      expect(result[:dead_letters]).to be_empty
    end
  end

  describe "on :with_retry — success after retries" do
    it "does not add a dead letter when callable eventually succeeds" do
      attempt  = 0
      callable = lambda do |**|
        attempt += 1
        raise "fail" if attempt < 2
        :ok
      end
      result = call_handler(:with_retry,
        payload: { callable: callable, args: {}, max_retries: 3,
                   backoff: :immediate, base_delay: 0 })
      expect(result[:dead_letters]).to be_empty
      expect(attempt).to eq(2)
    end
  end

  describe "on :with_retry — exhausts retries" do
    it "adds a DeadLetter entry when callable always fails" do
      callable = ->(**) { raise "permanent failure" }
      result   = call_handler(:with_retry,
        payload: { callable: callable, args: {}, max_retries: 2,
                   backoff: :immediate, base_delay: 0 })
      expect(result[:dead_letters].size).to eq(1)
    end

    it "records the error message in the dead letter" do
      callable = ->(**) { raise "boom" }
      result   = call_handler(:with_retry,
        payload: { callable: callable, args: {}, max_retries: 1,
                   backoff: :immediate, base_delay: 0 })
      letter = result[:dead_letters].first
      expect(letter.error).to eq("boom")
    end

    it "records the correct attempt count (max_retries + 1)" do
      callable = ->(**) { raise "x" }
      result   = call_handler(:with_retry,
        payload: { callable: callable, args: {}, max_retries: 3,
                   backoff: :immediate, base_delay: 0 })
      expect(result[:dead_letters].first.attempts).to eq(4)
    end

    it "forwards args to the callable" do
      received = {}
      callable = lambda do |x:, y:|
        received[:x] = x
        received[:y] = y
        raise "done"
      end
      call_handler(:with_retry,
        payload: { callable: callable, args: { x: 1, y: 2 },
                   max_retries: 0, backoff: :immediate, base_delay: 0 })
      expect(received).to eq({ x: 1, y: 2 })
    end
  end

  describe "backoff strategies (zero delay for speed)" do
    let(:failing) { ->(**) { raise "fail" } }

    it ":immediate uses zero delay" do
      start = Time.now
      call_handler(:with_retry,
        payload: { callable: failing, max_retries: 3,
                   backoff: :immediate, base_delay: 0 })
      expect(Time.now - start).to be < 0.5
    end

    it ":linear uses base_delay * attempt" do
      # Just verify it returns a dead letter (we can't easily test exact delay)
      result = call_handler(:with_retry,
        payload: { callable: failing, max_retries: 1,
                   backoff: :linear, base_delay: 0 })
      expect(result[:dead_letters]).not_to be_empty
    end

    it ":exponential uses base_delay * 2^(attempt-1)" do
      result = call_handler(:with_retry,
        payload: { callable: failing, max_retries: 1,
                   backoff: :exponential, base_delay: 0 })
      expect(result[:dead_letters]).not_to be_empty
    end
  end

  describe "on :dead_letters" do
    it "returns the dead letters array" do
      dead_letter = described_class::DeadLetter.new(
        callable: nil, args: {}, error: "e", attempts: 1, ts: 0
      )
      result = call_handler(:dead_letters,
        state: { dead_letters: [dead_letter] })
      expect(result).to eq([dead_letter])
    end
  end

  describe "on :clear_dead_letters" do
    it "empties the dead letter queue" do
      dead_letter = described_class::DeadLetter.new(
        callable: nil, args: {}, error: "e", attempts: 1, ts: 0
      )
      result = call_handler(:clear_dead_letters,
        state: { dead_letters: [dead_letter] })
      expect(result[:dead_letters]).to be_empty
    end
  end
end
