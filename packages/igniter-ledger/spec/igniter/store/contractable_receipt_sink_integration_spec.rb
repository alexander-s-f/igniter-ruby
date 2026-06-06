# frozen_string_literal: true

# Cross-package integration proof: igniter-embed contractable runner wired to
# igniter-ledger ContractableReceiptSink.
#
# Dependency direction: Store accepts receipt hashes emitted by Embed.
# Embed does not require Store.
#
# Load path is patched manually so igniter-ledger stays Rails/Embed-free.

require_relative "../../spec_helper"

STORE_SINK_INTEGRATION_ROOT = File.expand_path("../../../../..", __dir__)
  .freeze unless defined?(STORE_SINK_INTEGRATION_ROOT)

[
  "packages/igniter-embed/lib",
  "packages/igniter-extensions/lib",
  "packages/igniter-contracts/lib"
].each do |rel|
  path = File.expand_path(rel, STORE_SINK_INTEGRATION_ROOT)
  $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
end

require "igniter/embed"

RSpec.describe "ContractableReceiptSink integration with Embed contractable runner" do
  before { Igniter::Contracts.reset_defaults! }

  def normalizer
    ->(result) { { status: :ok, outputs: result.is_a?(Hash) ? result : {}, metadata: {} } }
  end

  def new_sink
    Igniter::Store::ContractableReceiptSink.new(
      store: Igniter::Store::IgniterStore.new
    )
  end

  it "returns the primary result unchanged when a sink is the store adapter" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount * 1.2 } }
      config.candidate ->(amount:) { { total: amount * 1.2 } }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    result = runner.call(amount: 100)
    expect(result).to eq(total: 120.0)
  end

  it "writes an observation receipt to the observation store" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount * 1.2 } }
      config.candidate ->(amount:) { { total: amount * 1.2 } }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    observations = sink.observations
    expect(observations.length).to eq(1)
    obs = observations.first
    expect(obs[:receipt_kind]).to eq(:contractable_observation)
    expect(obs[:observation_id]).to match(/\Aobs_[0-9a-f]{24}\z/)
    expect(obs[:name]).to eq(:quote)
    expect(obs[:status]).to eq(:ok)
    expect(obs[:match]).to eq(true)
    expect(obs[:accepted]).to eq(true)
  end

  it "writes divergence and acceptance_failure event receipts when outputs diverge" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount + 1 } }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    runner.call(amount: 100)

    error_events = sink.error_events
    all_event_types = sink.store.history(store: :contractable_events).map(&:value).map { |r| r[:event] }
    expect(all_event_types).to include(:divergence, :acceptance_failure)
    expect(error_events).to be_empty
  end

  it "writes candidate_error events when candidate raises" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { raise "candidate down" }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    errors = sink.error_events
    expect(errors.map { |r| r[:event] }).to include(:candidate_error)
  end

  it "links events to observations via shared observation_id" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount + 1 } }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    runner.call(amount: 100)

    obs = sink.observations.first
    obs_id = obs[:observation_id]
    events = sink.events_for(obs_id)

    expect(events).not_to be_empty
    events.each do |e|
      expect(e[:observation_id]).to eq(obs_id)
    end
  end

  it "replays events in commit order via events_for" do
    sink = new_sink
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { raise "boom" }
      config.async false
      config.store sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :completed
    end

    runner.call(amount: 100)

    obs_id = sink.observations.first[:observation_id]
    events = sink.events_for(obs_id)

    expect(events).not_to be_empty
    event_types = events.map { |e| e[:event] }
    expect(event_types).to include(:candidate_error, :observation)
  end

  it "does not alter the primary result even when the observation write fails" do
    # Simulate a store that raises on record_observation
    broken_sink = Class.new do
      def record_observation(_receipt)
        raise "broken"
      end

      def record_event(_receipt) = nil
    end.new

    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store broken_sink
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
  end
end
