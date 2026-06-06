# frozen_string_literal: true

require "spec_helper"
require "igniter/agents"

RSpec.describe Igniter::Agents::CronAgent do
  def call_handler(type, state: described_class.default_state, payload: {})
    described_class.handlers[type].call(state: state, payload: payload)
  end

  describe "on :add_job" do
    it "registers a job in state" do
      callable = -> {}
      result   = call_handler(:add_job,
        payload: { name: :cleanup, every: 3600, callable: callable })
      expect(result[:jobs]).to have_key(:cleanup)
    end

    it "coerces name to symbol" do
      result = call_handler(:add_job,
        payload: { name: "sync", every: 60, callable: -> {} })
      expect(result[:jobs]).to have_key(:sync)
    end

    it "schedules next_at in the future" do
      before = Time.now.to_f
      result = call_handler(:add_job,
        payload: { name: :j, every: 10, callable: -> {} })
      expect(result[:jobs][:j][:next_at]).to be >= before + 10
    end

    it "initialises runs to 0" do
      result = call_handler(:add_job,
        payload: { name: :j, every: 5, callable: -> {} })
      expect(result[:jobs][:j][:runs]).to eq(0)
    end

    it "overwrites an existing job with the same name" do
      state  = call_handler(:add_job, payload: { name: :j, every: 5, callable: -> {} })
      result = call_handler(:add_job, state: state,
        payload: { name: :j, every: 99, callable: -> {} })
      expect(result[:jobs][:j][:every]).to eq(99)
      expect(result[:jobs].size).to eq(1)
    end
  end

  describe "on :remove_job" do
    it "removes the job from state" do
      state  = call_handler(:add_job, payload: { name: :j, every: 5, callable: -> {} })
      result = call_handler(:remove_job, state: state, payload: { name: :j })
      expect(result[:jobs]).not_to have_key(:j)
    end

    it "is a no-op for unknown names" do
      expect do
        call_handler(:remove_job, payload: { name: :ghost })
      end.not_to raise_error
    end
  end

  describe "on :list_jobs" do
    it "returns an array of JobInfo structs" do
      state  = call_handler(:add_job, payload: { name: :j, every: 60, callable: -> {} })
      result = call_handler(:list_jobs, state: state)
      expect(result).to all(be_a(described_class::JobInfo))
    end

    it "includes name, every, and runs" do
      state  = call_handler(:add_job, payload: { name: :sync, every: 30, callable: -> {} })
      info   = call_handler(:list_jobs, state: state).first
      expect(info.name).to eq(:sync)
      expect(info.every).to eq(30)
      expect(info.runs).to eq(0)
    end

    it "returns empty array when no jobs are registered" do
      expect(call_handler(:list_jobs)).to be_empty
    end
  end

  describe "on :_tick" do
    let(:callable) { double("callable") }

    it "calls due jobs and increments their runs counter" do
      allow(callable).to receive(:call)
      past_time = Time.now.to_f - 1
      state = described_class.default_state.merge(
        jobs: { cleanup: { name: :cleanup, every: 60, callable: callable,
                           next_at: past_time, runs: 0 } }
      )
      result = call_handler(:_tick, state: state)
      expect(callable).to have_received(:call).once
      expect(result[:jobs][:cleanup][:runs]).to eq(1)
    end

    it "does not call jobs that are not yet due" do
      allow(callable).to receive(:call)
      state = described_class.default_state.merge(
        jobs: { future: { name: :future, every: 60, callable: callable,
                          next_at: Time.now.to_f + 9999, runs: 0 } }
      )
      call_handler(:_tick, state: state)
      expect(callable).not_to have_received(:call)
    end

    it "reschedules a job after it runs" do
      allow(callable).to receive(:call)
      past_time = Time.now.to_f - 1
      state = described_class.default_state.merge(
        jobs: { j: { name: :j, every: 60, callable: callable,
                     next_at: past_time, runs: 0 } }
      )
      result = call_handler(:_tick, state: state)
      expect(result[:jobs][:j][:next_at]).to be > Time.now.to_f
    end

    it "swallows errors from job callables" do
      exploding = -> { raise "boom" }
      state = described_class.default_state.merge(
        jobs: { j: { name: :j, every: 1, callable: exploding,
                     next_at: Time.now.to_f - 1, runs: 0 } }
      )
      expect { call_handler(:_tick, state: state) }.not_to raise_error
    end

    it "accepts an :at timestamp override for deterministic testing" do
      allow(callable).to receive(:call)
      at_time = 1_000_000.0
      state = described_class.default_state.merge(
        jobs: { j: { name: :j, every: 10, callable: callable,
                     next_at: at_time - 1, runs: 0 } }
      )
      result = call_handler(:_tick, state: state, payload: { at: at_time })
      expect(callable).to have_received(:call)
      expect(result[:jobs][:j][:next_at]).to eq(at_time + 10)
    end
  end
end
