# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Embed::Contractable do
  class EmbedSpecCoreContractableScorer
    include Igniter::Contracts::Contractable

    contractable :call do
      role :migration_candidate
      stage :shadowed
      meta :domain, :wellness
      input :sleep_hours
      output :score
    end

    def call(sleep_hours:)
      success(score: (sleep_hours * 10).round)
    end
  end

  def memory_store
    Class.new do
      attr_reader :observations

      def initialize
        @observations = []
      end

      def record(observation)
        observations << observation
      end
    end.new
  end

  def rich_store
    Class.new do
      attr_reader :observations, :events

      def initialize
        @observations = []
        @events = []
      end

      def record_observation(receipt)
        observations << receipt
      end

      def record_event(receipt)
        events << receipt
      end
    end.new
  end

  def queue_adapter
    Class.new do
      attr_reader :jobs

      def initialize
        @jobs = []
      end

      def enqueue(name:, inputs:, metadata:, handoff: nil, &block)
        jobs << { name: name, inputs: inputs, metadata: metadata, handoff: handoff, block: block }
      end
    end.new
  end

  def normalizer
    lambda do |result|
      {
        status: :ok,
        outputs: result,
        metadata: { normalized: true }
      }
    end
  end

  def contractable_payload_normalizer
    lambda do |payload|
      {
        status: payload.fetch(:status),
        outputs: payload.fetch(:outputs),
        metadata: payload.fetch(:metadata, {})
      }
    end
  end

  it "returns the primary result synchronously and records an exact match observation" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount * 1.2 } }
      config.candidate ->(amount:) { { total: amount * 1.2 } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    result = runner.call(amount: 100)

    expect(result).to eq(total: 120.0)
    observation = store.observations.fetch(0)
    expect(observation).to include(name: :quote, role: :migration_candidate, stage: :captured)
    expect(observation).to include(match: true, accepted: true)
    expect(observation.fetch(:report)).to include(match: true, summary: "match")
  end

  it "records divergences without changing the primary result" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount * 1.2 } }
      config.candidate ->(amount:) { { total: amount * 1.3 } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    expect(runner.call(amount: 100)).to eq(total: 120.0)

    observation = store.observations.fetch(0)
    expect(observation.fetch(:match)).to eq(false)
    expect(observation.fetch(:accepted)).to eq(false)
    expect(observation.dig(:report, :summary)).to include("value(s) differ")
  end

  it "captures candidate exceptions and accepts completed policy only when candidate completes" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { raise "candidate exploded" if amount }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :completed
    end

    expect(runner.call(amount: 100)).to eq(total: 100)

    observation = store.observations.fetch(0)
    expect(observation.fetch(:candidate)).to include(status: :error)
    expect(observation.dig(:candidate, :error, :message)).to eq("candidate exploded")
    expect(observation.fetch(:accepted)).to eq(false)
  end

  it "supports no-store mode" do
    observations = []
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.on_observation ->(observation) { observations << observation }
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
    expect(observations.length).to eq(1)
    expect(observations.first.fetch(:store_error)).to be_nil
  end

  it "enqueues candidate work through the async adapter" do
    store = memory_store
    queue = queue_adapter
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async true
      config.async_adapter queue
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
    expect(store.observations).to eq([])
    expect(queue.jobs.length).to eq(1)

    queue.jobs.first.fetch(:block).call
    expect(store.observations.length).to eq(1)
  end

  it "uses a non-blocking local thread adapter by default when async is true" do
    store = memory_store
    candidate_started = Queue.new
    release_candidate = Queue.new
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate lambda { |amount:|
        candidate_started << true
        release_candidate.pop
        { total: amount }
      }
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
    expect(candidate_started.pop).to eq(true)
    expect(store.observations).to eq([])

    release_candidate << true
    sleep 0.05 until store.observations.any?

    expect(store.observations.length).to eq(1)
  end

  it "supports primary-only observed service mode" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.role :observed_service
      config.stage :profiled
      config.primary ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)

    observation = store.observations.fetch(0)
    expect(observation).to include(role: :observed_service, stage: :profiled, mode: :observe)
    expect(observation.fetch(:candidate)).to be_nil
    expect(observation.fetch(:report)).to be_nil
  end

  it "adopts core contractable role, stage, and metadata defaults" do
    store = memory_store
    runner = Igniter::Embed.contractable(:body_battery) do |config|
      config.primary EmbedSpecCoreContractableScorer
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary contractable_payload_normalizer
    end

    result = runner.call(sleep_hours: 8)

    expect(runner.config.role).to eq(:migration_candidate)
    expect(runner.config.stage).to eq(:shadowed)
    expect(runner.config.metadata).to eq(domain: :wellness)
    expect(result).to include(status: :success, outputs: { score: 80 })
    observation = store.observations.fetch(0)
    expect(observation).to include(role: :migration_candidate, stage: :shadowed, mode: :observe)
    expect(observation.fetch(:primary)).to include(outputs: { score: 80 }, metadata: include(domain: :wellness))
  end

  it "supports shape acceptance over candidate outputs" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary -> { { total: 100 } }
      config.candidate -> { { total: 120, status: "accepted" } }
      config.async false
      config.store store
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :shape, outputs: { total: Numeric, status: String }
    end

    runner.call

    expect(store.observations.fetch(0).fetch(:accepted)).to eq(true)
  end

  it "supports migration sugar over contractable config" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount * 1.2 } },
              to: ->(amount:) { { total: amount * 1.2 } }
      shadow async: false, sample: 1.0
      store store
      redact_inputs ->(**inputs) { inputs }
      normalize_primary normalize
      normalize_candidate normalize
      accept :exact
    end

    expect(runner.config.role).to eq(:migration_candidate)
    expect(runner.config.stage).to eq(:shadowed)
    expect(runner.call(amount: 100)).to eq(total: 120.0)
    expect(store.observations.fetch(0)).to include(match: true, accepted: true)
  end

  it "supports visible adapter capability sugar over contractable config" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:, **) { { total: amount * 1.2, internal_id: "p1" } },
              to: ->(amount:, **) { { total: amount * 1.2, internal_id: "c1" } }
      shadow async: false, sample: 1.0
      use :normalizer, normalize
      use :redaction, only: %i[account_id quote_id]
      use :acceptance, policy: :completed
      use :store, store
    end

    expect(runner.config.normalize_primary).to eq(normalize)
    expect(runner.config.normalize_candidate).to eq(normalize)
    expect(runner.config.accept).to eq(:completed)
    expect(runner.config.store).to eq(store)

    runner.call(amount: 100, account_id: "acct_1", quote_id: "quote_1", token: "secret")
    observation = store.observations.fetch(0)

    expect(observation.fetch(:inputs)).to eq(account_id: "acct_1", quote_id: "quote_1")
    expect(observation.fetch(:accepted)).to eq(true)
  end

  it "supports redaction except sugar" do
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      observe ->(**inputs) { inputs }
      normalize_primary normalize
      use :redaction, except: :token
    end

    expect(runner.config.redact_inputs.call(account_id: "acct_1", token: "secret")).to eq(account_id: "acct_1")
  end

  it "rejects broad capability sugar outside the current slice" do
    expect do
      Igniter::Embed.contractable(:quote) do
        use :metrics
      end
    end.to raise_error(Igniter::Embed::SugarError, /use :metrics/)
  end

  it "raises a sugar error when acceptance sugar omits policy" do
    expect do
      Igniter::Embed.contractable(:quote) do
        use :acceptance
      end
    end.to raise_error(Igniter::Embed::SugarError, /policy/)
  end

  it "dispatches typed candidate error events" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { raise "candidate exploded" if amount }
      shadow async: false
      use :normalizer, normalize
      on :candidate_error do |event|
        events << event
      end
    end

    runner.call(amount: 100)

    expect(events.length).to eq(1)
    expect(events.first).to include(name: :quote, role: :migration_candidate, stage: :shadowed, event: :candidate_error)
    expect(events.first.dig(:error, :message)).to eq("candidate exploded")
  end

  it "expands failure alias into typed failure events" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { raise "candidate exploded" if amount }
      shadow async: false
      use :normalizer, normalize
      use :acceptance, policy: :completed
      on :failure do |event|
        events << event.fetch(:event)
      end
    end

    runner.call(amount: 100)

    expect(events).to include(:candidate_error, :acceptance_failure)
    expect(events).not_to include(:divergence)
  end

  it "dispatches divergence separately from failure alias" do
    divergence_events = []
    failure_events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      on :divergence do |event|
        divergence_events << event
      end
      on :failure do |event|
        failure_events << event
      end
    end

    runner.call(amount: 100)

    expect(divergence_events.length).to eq(1)
    expect(divergence_events.first.fetch(:event)).to eq(:divergence)
    expect(failure_events.map { |event| event.fetch(:event) }).to eq([:acceptance_failure])
  end

  it "dispatches primary error events before re-raising" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      observe -> { raise "primary exploded" }
      normalize_primary normalize
      on :failure do |event|
        events << event
      end
    end

    expect { runner.call }.to raise_error(RuntimeError, "primary exploded")
    expect(events.length).to eq(1)
    expect(events.first.fetch(:event)).to eq(:primary_error)
    expect(events.first.dig(:error, :message)).to eq("primary exploded")
  end

  it "supports observed service sugar over contractable config" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      observe ->(amount:) { { total: amount } }
      async false
      store store
      redact_inputs ->(**inputs) { inputs }
      normalize_primary normalize
    end

    expect(runner.config.role).to eq(:observed_service)
    expect(runner.config.stage).to eq(:captured)
    runner.call(amount: 100)

    observation = store.observations.fetch(0)
    expect(observation).to include(role: :observed_service, stage: :captured, mode: :observe)
  end

  it "supports discovery probe sugar over contractable config" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:vendor_lookup) do
      discover ->(vendor_id:) { { vendor_id: vendor_id } }
      capture calls: true, timing: true, errors: true
      async false
      store store
      redact_inputs ->(**inputs) { inputs }
      normalize_primary normalize
    end

    expect(runner.config.role).to eq(:discovery_probe)
    expect(runner.config.stage).to eq(:profiled)
    expect(runner.config.metadata).to eq(capture: { calls: true, timing: true, errors: true })
  end

  # --- Scope A: Canonical Observation Receipt Shape ---

  it "includes schema_version, receipt_kind, and stable observation_id in observations" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    observation = store.observations.fetch(0)
    expect(observation.fetch(:schema_version)).to eq(1)
    expect(observation.fetch(:receipt_kind)).to eq(:contractable_observation)
    expect(observation.fetch(:observation_id)).to match(/\Aobs_[0-9a-f]{24}\z/)
  end

  it "generates a unique observation_id per call" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)
    runner.call(amount: 200)

    ids = store.observations.map { |o| o.fetch(:observation_id) }
    expect(ids.uniq.length).to eq(2)
  end

  it "sets status :ok for matching observation" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    runner.call(amount: 100)
    expect(store.observations.fetch(0).fetch(:status)).to eq(:ok)
  end

  it "sets status :diverged when candidate diverges but acceptance passes" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount + 1 } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :completed
    end

    runner.call(amount: 100)
    expect(store.observations.fetch(0).fetch(:status)).to eq(:diverged)
  end

  it "sets status :candidate_error when candidate raises" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(_amount:) { raise "boom" }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)
    expect(store.observations.fetch(0).fetch(:status)).to eq(:candidate_error)
  end

  it "sets status :acceptance_failed when candidate succeeds but acceptance policy fails" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount + 1 } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.accept :exact
    end

    runner.call(amount: 100)
    expect(store.observations.fetch(0).fetch(:status)).to eq(:acceptance_failed)
  end

  it "sets status :unsampled when observation is not sampled" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.sample 0.0
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)
    expect(store.observations.fetch(0).fetch(:status)).to eq(:unsampled)
  end

  it "sets status :store_error when store adapter raises" do
    broken_store = Class.new do
      def record(_observation)
        raise "store is down"
      end
    end.new

    observations = []
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store broken_store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
      config.on_observation ->(obs) { observations << obs }
    end

    result = runner.call(amount: 100)
    expect(result).to eq(total: 100)
    expect(observations.fetch(0).fetch(:status)).to eq(:store_error)
  end

  # --- Scope B: Durable Event Receipts ---

  it "attaches a receipt to event payloads" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      on :divergence do |event|
        events << event
      end
    end

    runner.call(amount: 100)

    receipt = events.first.fetch(:receipt)
    expect(receipt.fetch(:schema_version)).to eq(1)
    expect(receipt.fetch(:receipt_kind)).to eq(:contractable_event)
    expect(receipt.fetch(:event_id)).to match(/\Aevt_[0-9a-f]{24}\z/)
    expect(receipt.fetch(:observation_id)).to match(/\Aobs_[0-9a-f]{24}\z/)
    expect(receipt.fetch(:event)).to eq(:divergence)
    expect(receipt.fetch(:severity)).to eq(:warning)
    expect(receipt.fetch(:summary)).to eq("outputs diverged from primary")
  end

  it "includes observation_ref in event receipts when observation is present" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      on :divergence do |event|
        events << event
      end
    end

    runner.call(amount: 100)

    observation_ref = events.first.dig(:receipt, :observation_ref)
    expect(observation_ref).to include(match: false, accepted: false)
    expect(observation_ref.fetch(:observation_id)).to match(/\Aobs_[0-9a-f]{24}\z/)
  end

  it "links event receipt observation_id to the observation receipt observation_id" do
    observations = []
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      on :divergence do |event|
        events << event
      end
      on_observation ->(obs) { observations << obs }
    end

    runner.call(amount: 100)

    obs_id = observations.first.fetch(:observation_id)
    event_obs_id = events.first.dig(:receipt, :observation_id)
    expect(event_obs_id).to eq(obs_id)
  end

  it "assigns :error severity to primary_error events" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      observe -> { raise "primary exploded" }
      normalize_primary normalize
      on :primary_error do |event|
        events << event
      end
    end

    expect { runner.call }.to raise_error(RuntimeError)
    expect(events.first.dig(:receipt, :severity)).to eq(:error)
  end

  it "sets observation_ref to nil in event receipts when no observation is available" do
    events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      observe -> { raise "primary exploded" }
      normalize_primary normalize
      on :primary_error do |event|
        events << event
      end
    end

    expect { runner.call }.to raise_error(RuntimeError)
    expect(events.first.dig(:receipt, :observation_ref)).to be_nil
  end

  # --- Scope C: Store Adapter Protocol Upgrade ---

  it "calls record_observation when the store adapter supports it" do
    store = rich_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    expect(store.observations.length).to eq(1)
    expect(store.observations.first).to include(receipt_kind: :contractable_observation)
  end

  it "calls record_event for each event when the store adapter supports it" do
    store = rich_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      use :store, store
    end

    runner.call(amount: 100)

    event_types = store.events.map { |e| e.fetch(:event) }
    expect(event_types).to include(:divergence, :acceptance_failure, :observation)
    store.events.each do |receipt|
      expect(receipt.fetch(:receipt_kind)).to eq(:contractable_event)
      expect(receipt.fetch(:schema_version)).to eq(1)
    end
  end

  it "still calls user event handlers even when record_event is present" do
    store = rich_store
    divergence_events = []
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:) { { total: amount } },
              to: ->(amount:) { { total: amount + 1 } }
      shadow async: false
      use :normalizer, normalize
      use :store, store
      on :divergence do |event|
        divergence_events << event
      end
    end

    runner.call(amount: 100)

    expect(divergence_events.length).to eq(1)
    expect(store.events.map { |e| e[:event] }).to include(:divergence)
  end

  it "falls back to record(observation) for legacy store adapters" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    expect(store.observations.length).to eq(1)
    expect(store.observations.first).to include(receipt_kind: :contractable_observation)
  end

  it "does not raise when store raises — primary result is unaffected" do
    broken_store = Class.new do
      def record(_observation)
        raise "store is down"
      end
    end.new

    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store broken_store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
  end

  # --- Scope D: Redaction Policy Metadata ---

  it "includes redaction metadata in observation receipts" do
    store = memory_store
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async false
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    redaction = store.observations.first.fetch(:redaction)
    expect(redaction).to include(input_policy: :custom, output_policy: :none, classes: [])
  end

  it "reflects :only redaction policy in observation receipts" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:, **) { { total: amount } },
              to: ->(amount:, **) { { total: amount } }
      shadow async: false
      use :normalizer, normalize
      use :redaction, only: %i[amount]
      use :store, store
    end

    runner.call(amount: 100, token: "secret")

    redaction = store.observations.first.fetch(:redaction)
    expect(redaction.fetch(:input_policy)).to eq(:only)
  end

  it "reflects :except redaction policy in observation receipts" do
    store = memory_store
    normalize = normalizer
    runner = Igniter::Embed.contractable(:quote) do
      migrate ->(amount:, **) { { total: amount } },
              to: ->(amount:, **) { { total: amount } }
      shadow async: false
      use :normalizer, normalize
      use :redaction, except: :token
      use :store, store
    end

    runner.call(amount: 100, token: "secret")

    redaction = store.observations.first.fetch(:redaction)
    expect(redaction.fetch(:input_policy)).to eq(:except)
  end

  # --- Scope E: Async Handoff Descriptor ---

  it "passes a handoff descriptor to async adapters that accept it" do
    store = memory_store
    queue = queue_adapter
    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async true
      config.async_adapter queue
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    runner.call(amount: 100)

    job = queue.jobs.first
    handoff = job.fetch(:handoff)
    expect(handoff).not_to be_nil
    expect(handoff.fetch(:schema_version)).to eq(1)
    expect(handoff.fetch(:kind)).to eq(:contractable_async_handoff)
    expect(handoff.fetch(:observation_id)).to match(/\Aobs_[0-9a-f]{24}\z/)
    expect(handoff.fetch(:name)).to eq(:quote)
    expect(handoff).to have_key(:queued_at)
  end

  it "falls back gracefully to adapters that do not accept handoff:" do
    store = memory_store
    legacy_queue = Class.new do
      attr_reader :jobs

      def initialize
        @jobs = []
      end

      def enqueue(name:, inputs:, metadata:, &block)
        jobs << { name: name, inputs: inputs, metadata: metadata, block: block }
      end
    end.new

    runner = Igniter::Embed.contractable(:quote) do |config|
      config.primary ->(amount:) { { total: amount } }
      config.candidate ->(amount:) { { total: amount } }
      config.async true
      config.async_adapter legacy_queue
      config.store store
      config.redact_inputs ->(**inputs) { inputs }
      config.normalize_primary normalizer
      config.normalize_candidate normalizer
    end

    expect(runner.call(amount: 100)).to eq(total: 100)
    legacy_queue.jobs.first.fetch(:block).call
    expect(store.observations.length).to eq(1)
  end
end
