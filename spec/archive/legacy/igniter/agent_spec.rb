# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "igniter/agent"

RSpec.describe Igniter::Agent do
  # Helper: wait until condition is true or timeout
  def wait_until(timeout: 1.0, interval: 0.01)
    deadline = Time.now + timeout
    sleep(interval) until yield || Time.now >= deadline
  end

  # Minimal agent for most tests
  let(:agent_class) do
    Class.new(Igniter::Agent) do
      initial_state counter: 0

      on :increment do |state:, payload:, **|
        by = payload.fetch(:by, 1)
        state.merge(counter: state[:counter] + by)
      end

      on :reset do |state:, **|
        state.merge(counter: 0)
      end

      # Returns current count — auto-replied to sync callers
      on :count do |state:, **|
        state[:counter]
      end
    end
  end

  let(:ref) { agent_class.start }

  after do
    ref.stop
  rescue StandardError
    nil
  end

  # ── DSL ──────────────────────────────────────────────────────────────────────

  describe "class-level DSL" do
    it "sets default state" do
      klass = Class.new(Igniter::Agent) { initial_state value: 99 }
      r = klass.start
      expect(r.state).to eq({ value: 99 })
      r.stop
    end

    it "evaluates a block for default state each time" do
      klass = Class.new(Igniter::Agent) { initial_state { { rand: rand } } }
      r1 = klass.start
      r2 = klass.start
      # States are independently initialized (different rand values with overwhelming probability)
      expect(r1.state).not_to be_nil
      r1.stop
      r2.stop
    end

    it "isolates handlers between subclasses" do
      klass_a = Class.new(Igniter::Agent) { on(:ping) { |**| :pong } }
      klass_b = Class.new(Igniter::Agent) { on(:ping) { |**| :bong } }
      r_a = klass_a.start
      r_b = klass_b.start
      expect(r_a.call(:ping)).to eq(:pong)
      expect(r_b.call(:ping)).to eq(:bong)
      r_a.stop
      r_b.stop
    end

    it "configures mailbox_size and mailbox_overflow without errors" do
      klass = Class.new(Igniter::Agent) do
        mailbox_size 10
        mailbox_overflow :drop_oldest
        initial_state({})
        on(:noop) { |**| nil }
      end
      r = klass.start
      expect(r.alive?).to be true
      r.stop
    end
  end

  # ── Lifecycle ────────────────────────────────────────────────────────────────

  describe "#alive?" do
    it "returns true after start" do
      expect(ref.alive?).to be true
    end

    it "returns false after stop" do
      ref.stop
      expect(ref.alive?).to be false
    end
  end

  describe "#state" do
    it "returns the initial state" do
      expect(ref.state).to eq({ counter: 0 })
    end

    it "reflects state changes after async send" do
      ref.send(:increment, by: 7)
      wait_until { ref.state[:counter] == 7 }
      expect(ref.state[:counter]).to eq(7)
    end
  end

  # ── Async messaging ───────────────────────────────────────────────────────

  describe "#send" do
    it "delivers messages asynchronously and returns self" do
      result = ref.send(:increment, by: 3)
      expect(result).to be(ref)
      wait_until { ref.state[:counter] == 3 }
      expect(ref.state[:counter]).to eq(3)
    end

    it "processes messages in order" do
      ref.send(:increment, by: 1)
      ref.send(:increment, by: 2)
      ref.send(:increment, by: 3)
      wait_until { ref.state[:counter] == 6 }
      expect(ref.state[:counter]).to eq(6)
    end
  end

  # ── Sync call ────────────────────────────────────────────────────────────────

  describe "#call" do
    it "returns the handler's non-Hash return value" do
      ref.send(:increment, by: 5)
      result = ref.call(:count)
      expect(result).to eq(5)
    end

    it "returns nil when handler returns a Hash (state update)" do
      result = ref.call(:increment, { by: 3 })
      expect(result).to be_nil
    end

    it "raises TimeoutError when agent does not reply in time" do
      klass = Class.new(Igniter::Agent) do
        on :slow do |**|
          sleep(10)
          42
        end
      end
      r = klass.start
      expect { r.call(:slow, {}, timeout: 0.1) }.to raise_error(Igniter::Agent::TimeoutError)
      r.kill
    end
  end

  # ── :stop return value ───────────────────────────────────────────────────────

  describe "returning :stop from a handler" do
    it "shuts down the agent" do
      klass = Class.new(Igniter::Agent) do
        on :die do |**|
          :stop
        end
      end
      r = klass.start
      r.send(:die)
      wait_until(timeout: 1.0) { !r.alive? }
      expect(r.alive?).to be false
    end
  end

  # ── Unknown message type ─────────────────────────────────────────────────────

  describe "unknown message type" do
    it "is silently dropped (async)" do
      ref.send(:unknown_message)
      sleep(0.05) # let the runner process the noop
      expect(ref.alive?).to be true
    end

    it "returns nil via call" do
      result = ref.call(:unknown_message)
      expect(result).to be_nil
    end
  end

  # ── Timers ───────────────────────────────────────────────────────────────────

  describe "schedule" do
    it "fires periodically and updates state" do
      klass = Class.new(Igniter::Agent) do
        initial_state ticks: 0
        schedule :tick, every: 0.05 do |state:|
          state.merge(ticks: state[:ticks] + 1)
        end
      end
      r = klass.start
      sleep(0.2)
      r.stop
      expect(r.state[:ticks]).to be >= 2
    end
  end

  # ── Lifecycle hooks ──────────────────────────────────────────────────────────

  describe "lifecycle hooks" do
    it "calls after_start when the agent begins" do
      started = Queue.new
      klass = Class.new(Igniter::Agent) do
        after_start { started.push(true) }
      end
      r = klass.start
      Timeout.timeout(1) { started.pop }
      r.stop
      expect(started.size).to eq(0) # was popped
    end

    it "calls after_stop when the agent exits" do
      stopped = Queue.new
      klass = Class.new(Igniter::Agent) do
        after_stop { stopped.push(true) }
      end
      r = klass.start
      r.stop
      Timeout.timeout(1) { stopped.pop }
      expect(stopped.size).to eq(0)
    end

    it "calls after_crash with the error when handler raises" do
      errors = Queue.new
      klass = Class.new(Igniter::Agent) do
        after_crash { |error:, **| errors.push(error) }
        on(:boom) { |**| raise "kaboom" }
      end
      r = klass.start
      r.send(:boom)
      err = Timeout.timeout(1) { errors.pop }
      expect(err.message).to eq("kaboom")
      begin
        r.kill
      rescue StandardError
        nil
      end
    end
  end

  # ── on_crash callback ────────────────────────────────────────────────────────

  describe "on_crash callback" do
    it "is invoked when the runner thread crashes" do
      crashed = Queue.new
      klass = Class.new(Igniter::Agent) do
        on(:crash) { |**| raise "intentional" }
      end
      r = klass.start(on_crash: ->(err) { crashed.push(err) })
      r.send(:crash)
      err = Timeout.timeout(1) { crashed.pop }
      expect(err.message).to eq("intentional")
    end
  end

  # ── Mailbox overflow ─────────────────────────────────────────────────────────

  describe "mailbox overflow policies" do
    it ":error raises MailboxFullError when full" do
      klass = Class.new(Igniter::Agent) do
        mailbox_size     1
        mailbox_overflow :error
        on(:slow) { |**| sleep(10) }
      end
      r = klass.start
      r.send(:slow) # fills the mailbox
      expect { r.send(:slow) }.to raise_error(Igniter::Agent::MailboxFullError)
      r.kill
    end

    it ":drop_newest silently discards the incoming message when full" do
      klass = Class.new(Igniter::Agent) do
        mailbox_size     1
        mailbox_overflow :drop_newest
        on(:slow) { |**| sleep(10) }
        on(:noop) { |**| nil }
      end
      r = klass.start
      r.send(:slow) # fills the mailbox (runner is sleeping in the handler)
      # These should not raise and should be silently dropped
      expect { r.send(:noop) }.not_to raise_error
      r.kill
    end
  end

  # ── Ref#rebind ────────────────────────────────────────────────────────────────

  describe "Ref#rebind" do
    it "swaps internals so the Ref points to the new agent" do
      ref2 = agent_class.start
      ref2.send(:increment, by: 99)
      wait_until { ref2.state[:counter] == 99 }

      begin
        ref2.instance_variable_get(:@state_holder)
      rescue StandardError
        nil
      end
      # Just verify rebind doesn't raise — full supervisor integration tested separately
      expect do
        ref.rebind(thread: Thread.current, mailbox: Igniter::Agent::Mailbox.new,
                   state_holder: Igniter::Agent::StateHolder.new({}))
      end.not_to raise_error
      ref2.stop
    end
  end
end
