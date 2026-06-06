# frozen_string_literal: true

require_relative "../../spec_helper"

LEDGER_CLIENT_LIB = File.expand_path("../../../../igniter-ledger-client/lib", __dir__)
$LOAD_PATH.unshift(LEDGER_CLIENT_LIB) unless $LOAD_PATH.include?(LEDGER_CLIENT_LIB)

require "igniter-ledger-client"

RSpec.describe Igniter::Store::ContractableReceiptSink do
  def new_sink(**opts)
    described_class.new(store: Igniter::Store::IgniterStore.new, **opts)
  end

  def new_client_sink(**opts)
    engine = Igniter::Store::IgniterStore.new
    client = Igniter::LedgerClient.wrap(engine.protocol)
    described_class.new(client: client, **opts)
  end

  class RecordingTransport
    attr_reader :requests

    def initialize
      @requests = []
    end

    def dispatch(envelope)
      @requests << envelope
      result = case envelope[:op]
               when :register_descriptor
                 { accepted: true }
               when :append
                 { accepted: true, store: envelope[:packet][:history], key: "generated-key", fact_id: "fact-1" }
               else
                 raise "unexpected op: #{envelope[:op].inspect}"
               end

      {
        protocol: :igniter_store,
        schema_version: 1,
        request_id: envelope[:request_id],
        status: :ok,
        result: result
      }
    end
  end

  def observation_receipt(overrides = {})
    {
      schema_version: 1,
      receipt_kind: :contractable_observation,
      observation_id: "obs_abc123",
      name: :lead_decision,
      role: :migration_candidate,
      stage: :shadowed,
      mode: :shadow,
      sampled: true,
      async: false,
      status: :ok,
      started_at: "2026-05-04T10:00:00Z",
      finished_at: "2026-05-04T10:00:00.012Z",
      duration_ms: 12.0,
      inputs: { amount: 100 },
      primary: { status: :ok, outputs: { total: 120 }, metadata: {}, error: nil },
      candidate: { status: :ok, outputs: { total: 120 }, metadata: {}, error: nil },
      report: { match: true, summary: "match", details: {} },
      match: true,
      accepted: true,
      acceptance: { policy: :exact, accepted: true, failures: [] },
      error: nil,
      store_error: nil,
      metadata: {},
      redaction: { input_policy: :custom, output_policy: :none, classes: [] }
    }.merge(overrides)
  end

  def event_receipt(overrides = {})
    {
      schema_version: 1,
      receipt_kind: :contractable_event,
      event_id: "evt_def456",
      observation_id: "obs_abc123",
      event: :divergence,
      name: :lead_decision,
      occurred_at: "2026-05-04T10:00:00Z",
      severity: :warning,
      summary: "outputs diverged from primary",
      observation_ref: { observation_id: "obs_abc123", match: false, accepted: false },
      metadata: {}
    }.merge(overrides)
  end

  # --- Construction and descriptors (Scope B) ---

  it "registers protocol descriptors on construction" do
    sink = new_sink
    snapshot = sink.store.protocol.metadata_snapshot
    expect(snapshot[:stores].keys).to include(:contractable_observations)
    expect(snapshot[:histories].keys).to include(:contractable_events)
  end

  it "accepts custom store/events names" do
    sink = new_sink(observations_store: :my_obs, events_store: :my_events)
    snapshot = sink.store.protocol.metadata_snapshot
    expect(snapshot[:stores].keys).to include(:my_obs)
    expect(snapshot[:histories].keys).to include(:my_events)
  end

  it "can be constructed with a LedgerClient instead of a local store" do
    sink = new_client_sink
    snapshot = sink.client.metadata_snapshot
    expect(snapshot[:stores].keys).to include(:contractable_observations)
    expect(snapshot[:histories].keys).to include(:contractable_events)
  end

  it "requires either store: or client:" do
    expect { described_class.new }.to raise_error(ArgumentError, /store: or client:/)
  end

  # --- record_observation (Scope A) ---

  it "writes an observation fact keyed by observation_id" do
    sink = new_sink
    sink.record_observation(observation_receipt)
    result = sink.observation("obs_abc123")
    expect(result).to include(receipt_kind: :contractable_observation, observation_id: "obs_abc123", status: :ok)
  end

  it "returns the written fact from record_observation" do
    sink = new_sink
    fact = sink.record_observation(observation_receipt)
    expect(fact).to respond_to(:id)
    expect(fact).to respond_to(:value)
  end

  it "writes and reads observation receipts through LedgerClient" do
    sink = new_client_sink
    result = sink.record_observation(observation_receipt)

    expect(result).to respond_to(:accepted?)
    expect(result).to be_accepted
    expect(sink.observation("obs_abc123")).to include(
      receipt_kind: :contractable_observation,
      observation_id: "obs_abc123",
      status: :ok
    )
  end

  it "overwrites an observation on retry with the same observation_id" do
    sink = new_sink
    sink.record_observation(observation_receipt)
    sink.record_observation(observation_receipt(status: :diverged))
    result = sink.observation("obs_abc123")
    expect(result[:status]).to eq(:diverged)
  end

  it "raises ArgumentError for observation missing required fields" do
    sink = new_sink
    expect do
      sink.record_observation({ receipt_kind: :contractable_observation })
    end.to raise_error(ArgumentError, /observation_id/)
  end

  it "raises ArgumentError when observation receipt_kind is wrong" do
    sink = new_sink
    expect do
      sink.record_observation(observation_receipt(receipt_kind: :contractable_event))
    end.to raise_error(ArgumentError, /expected receipt_kind :contractable_observation/)
  end

  it "propagates store write errors to the caller" do
    broken_store = Class.new do
      def write(...)
        raise "store on fire"
      end

      def register_descriptor(*) = nil
    end.new
    sink = described_class.new(store: broken_store)
    expect { sink.record_observation(observation_receipt) }.to raise_error(RuntimeError, "store on fire")
  end

  # --- record_event (Scope A) ---

  it "appends an event fact to the events history" do
    sink = new_sink
    sink.record_observation(observation_receipt)
    sink.record_event(event_receipt)
    events = sink.events_for("obs_abc123")
    expect(events.length).to eq(1)
    expect(events.first).to include(receipt_kind: :contractable_event, event: :divergence)
  end

  it "returns the appended fact from record_event" do
    sink = new_sink
    fact = sink.record_event(event_receipt)
    expect(fact).to respond_to(:id)
  end

  it "records events through client append rather than write" do
    transport = RecordingTransport.new
    client = Igniter::LedgerClient::Client.new(transport: transport)
    sink = described_class.new(client: client)

    sink.record_event(event_receipt)

    append_request = transport.requests.last
    expect(append_request[:op]).to eq(:append)
    expect(transport.requests.map { |r| r[:op] }).not_to include(:write)
    expect(append_request[:packet]).to include(
      history: :contractable_events,
      partition_key: :observation_id,
      producer: { type: :embed, name: :contractable_receipt_sink }
    )
    expect(append_request[:packet][:event]).to include(event_id: "evt_def456")
  end

  it "raises ArgumentError for event missing required fields" do
    sink = new_sink
    expect do
      sink.record_event({ receipt_kind: :contractable_event, observation_id: "obs_abc123" })
    end.to raise_error(ArgumentError, /event_id/)
  end

  it "raises ArgumentError when event receipt_kind is wrong" do
    sink = new_sink
    expect do
      sink.record_event(event_receipt(receipt_kind: :contractable_observation))
    end.to raise_error(ArgumentError, /expected receipt_kind :contractable_event/)
  end

  # --- events_for (Scope C) ---

  it "returns all events for an observation_id in commit order" do
    sink = new_sink
    sink.record_event(event_receipt(event_id: "evt_1", event: :divergence))
    sink.record_event(event_receipt(event_id: "evt_2", event: :acceptance_failure))
    sink.record_event(event_receipt(event_id: "evt_3", event: :observation, observation_id: "obs_other"))

    events = sink.events_for("obs_abc123")
    expect(events.length).to eq(2)
    expect(events.map { |e| e[:event] }).to eq(%i[divergence acceptance_failure])
  end

  it "reconstructs events_for through LedgerClient replay" do
    sink = new_client_sink
    sink.record_event(event_receipt(event_id: "evt_1", event: :divergence))
    sink.record_event(event_receipt(event_id: "evt_2", event: :acceptance_failure))
    sink.record_event(event_receipt(event_id: "evt_3", event: :observation, observation_id: "obs_other"))

    events = sink.events_for("obs_abc123")
    expect(events.length).to eq(2)
    expect(events.map { |e| e[:event] }).to eq(%i[divergence acceptance_failure])
  end

  it "returns [] when no events are recorded for the given observation_id" do
    sink = new_sink
    expect(sink.events_for("obs_unknown")).to eq([])
  end

  # --- observations (Scope C) ---

  it "returns all current observations" do
    sink = new_sink
    sink.record_observation(observation_receipt(observation_id: "obs_1", name: :svc_a, status: :ok))
    sink.record_observation(observation_receipt(observation_id: "obs_2", name: :svc_b, status: :diverged))
    results = sink.observations
    expect(results.length).to eq(2)
    ids = results.map { |r| r[:observation_id] }
    expect(ids).to contain_exactly("obs_1", "obs_2")
  end

  it "returns the latest state when an observation_id is recorded twice" do
    sink = new_sink
    sink.record_observation(observation_receipt(observation_id: "obs_1", status: :ok))
    sink.record_observation(observation_receipt(observation_id: "obs_1", status: :diverged))
    results = sink.observations
    expect(results.length).to eq(1)
    expect(results.first[:status]).to eq(:diverged)
  end

  it "returns latest observations through LedgerClient replay" do
    sink = new_client_sink
    sink.record_observation(observation_receipt(observation_id: "obs_1", status: :ok))
    sink.record_observation(observation_receipt(observation_id: "obs_1", status: :diverged))
    sink.record_observation(observation_receipt(observation_id: "obs_2", status: :ok))

    results = sink.observations
    expect(results.length).to eq(2)
    expect(results.find { |r| r[:observation_id] == "obs_1" }[:status]).to eq(:diverged)
  end

  it "filters observations by status" do
    sink = new_sink
    sink.record_observation(observation_receipt(observation_id: "obs_1", status: :ok))
    sink.record_observation(observation_receipt(observation_id: "obs_2", status: :diverged))
    sink.record_observation(observation_receipt(observation_id: "obs_3", status: :diverged))
    results = sink.observations(status: :diverged)
    expect(results.length).to eq(2)
    expect(results.map { |r| r[:status] }.uniq).to eq([:diverged])
  end

  it "limits observations by count" do
    sink = new_sink
    5.times { |i| sink.record_observation(observation_receipt(observation_id: "obs_#{i}")) }
    expect(sink.observations(limit: 3).length).to eq(3)
  end

  # --- error_events (Scope C) ---

  it "returns only error-severity events" do
    sink = new_sink
    sink.record_event(event_receipt(event_id: "evt_1", severity: :warning, event: :divergence))
    sink.record_event(event_receipt(event_id: "evt_2", severity: :error, event: :candidate_error))
    sink.record_event(event_receipt(event_id: "evt_3", severity: :error, event: :store_error))
    sink.record_event(event_receipt(event_id: "evt_4", severity: :info, event: :observation))

    results = sink.error_events
    expect(results.length).to eq(2)
    expect(results.map { |r| r[:event] }).to contain_exactly(:candidate_error, :store_error)
  end

  it "limits error_events by count" do
    sink = new_sink
    4.times { |i| sink.record_event(event_receipt(event_id: "evt_#{i}", severity: :error)) }
    expect(sink.error_events(limit: 2).length).to eq(2)
  end

  it "returns [] when no error events exist" do
    sink = new_sink
    sink.record_event(event_receipt(event_id: "evt_1", severity: :info))
    expect(sink.error_events).to eq([])
  end
end
