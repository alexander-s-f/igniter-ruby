# frozen_string_literal: true

require "spec_helper"
require "igniter/supervisor"

RSpec.describe Igniter::Supervisor do
  def wait_until(timeout: 1.5, interval: 0.01)
    deadline = Time.now + timeout
    sleep(interval) until yield || Time.now >= deadline
  end

  let(:counter_class) do
    Class.new(Igniter::Agent) do
      initial_state counter: 0
      on(:increment) { |state:, payload:, **| state.merge(counter: state[:counter] + payload.fetch(:by, 1)) }
      on(:count)     { |state:, **| state[:counter] }
    end
  end

  let(:sup_class) do
    cc = counter_class
    Class.new(Igniter::Supervisor) do
      strategy     :one_for_one
      max_restarts 3, within: 10
      children do |c|
        c.worker :counter, cc
      end
    end
  end

  let(:sup) { sup_class.start }

  after do
    sup.stop
  rescue StandardError
    nil
  end

  # ── Startup ──────────────────────────────────────────────────────────────────

  describe ".start" do
    it "starts all declared children" do
      ref = sup.child(:counter)
      expect(ref).not_to be_nil
      expect(ref.alive?).to be true
    end
  end

  describe "#child" do
    it "returns nil for unknown names" do
      expect(sup.child(:nonexistent)).to be_nil
    end

    it "returns the ref for a known child" do
      expect(sup.child(:counter)).to be_a(Igniter::Agent::Ref)
    end
  end

  # ── Message passing through supervisor ───────────────────────────────────────

  it "routes messages to children" do
    sup.child(:counter).send(:increment, by: 7)
    wait_until { sup.child(:counter).state[:counter] == 7 }
    expect(sup.child(:counter).call(:count)).to eq(7)
  end

  # ── one_for_one restart ──────────────────────────────────────────────────────

  describe "one_for_one strategy" do
    it "restarts a crashed agent" do
      crasher_class = Class.new(Igniter::Agent) do
        initial_state alive: true
        on(:boom) { |**| raise "intentional crash" }
        on(:alive?) { |state:, **| state[:alive] }
      end

      crash_sup_class = Class.new(Igniter::Supervisor) do
        strategy     :one_for_one
        max_restarts 5, within: 10
      end
      crash_sup_class.children { |c| c.worker :crasher, crasher_class }
      crash_sup = crash_sup_class.start

      original_ref = crash_sup.child(:crasher)
      original_ref.send(:boom)

      wait_until(timeout: 2.0) { !original_ref.alive? }

      # Supervisor should restart the agent; child(:crasher) returns same Ref object
      wait_until(timeout: 2.0) { crash_sup.child(:crasher).alive? }
      expect(crash_sup.child(:crasher).alive?).to be true

      crash_sup.stop
    end
  end

  # ── Restart budget ────────────────────────────────────────────────────────────

  describe "restart budget" do
    it "stops restarting after budget is exceeded" do
      crasher_class = Class.new(Igniter::Agent) do
        on(:boom) { |**| raise "crash" }
      end

      tight_sup_class = Class.new(Igniter::Supervisor) do
        strategy     :one_for_one
        max_restarts 2, within: 60
      end
      tight_sup_class.children { |c| c.worker :crasher, crasher_class }
      tight_sup = tight_sup_class.start

      # Crash the agent more than budget allows
      # After max_restarts (2) is exceeded the supervisor stops restarting,
      # so the child will no longer be alive.
      3.times do
        ref = tight_sup.child(:crasher)
        ref.send(:boom) if ref&.alive?
        wait_until(timeout: 1.0) { !tight_sup.child(:crasher)&.alive? }
      end

      sleep(0.2)

      # After budget exceeded the agent stays dead
      expect(tight_sup.child(:crasher)&.alive?).to be_falsy

      begin
        tight_sup.stop
      rescue StandardError
        nil
      end
    end
  end

  # ── Stop ─────────────────────────────────────────────────────────────────────

  describe "#stop" do
    it "stops all children" do
      ref = sup.child(:counter)
      sup.stop
      wait_until { !ref.alive? }
      expect(ref.alive?).to be false
    end
  end
end
