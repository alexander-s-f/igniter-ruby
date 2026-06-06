# Igniter Embed

`igniter-embed` is the host-local layer for applications that want to register,
cache, and execute Igniter contracts without adopting the full application
runtime.

```ruby
contracts = Igniter::Embed.configure(:sparkcrm) do |config|
  config.cache = true
  config.pack Igniter::Contracts::ProjectPack
end

contracts.register(:tax_quote) do
  input :amount
  compute :tax, depends_on: [:amount] do |amount:|
    amount * 0.2
  end
  output :tax
end

result = contracts.call(:tax_quote, amount: 100)
result.success?
result.output(:tax)
```

For human-facing app initializers, `host` is sugar over the same host-local
configuration:

```ruby
contracts = Igniter::Embed.host(:shop) do
  owner Shop
  path "app/contracts"
  cache !Rails.env.development?

  contracts do
    add :price_quote, PriceContract
  end
end
```

For app-local contract classes, prefer host-level registration:

```ruby
class PriceContract < Igniter::Contract
  define do
    input :amount
    compute :total, depends_on: [:amount] do |amount:|
      amount * 1.2
    end
    output :total
  end
end

contracts = Igniter::Embed.configure(:shop) do |config|
  config.root "app/contracts"
  config.contract PriceContract, as: :price_quote
end

contracts.call(:price_quote, amount: 100).output(:total)
```

Named contract classes can also be registered directly:

```ruby
contracts.register(PriceContract)
contracts.call(:price, amount: 100)
```

`config.root` is the host-local directory where contract files live. It is
metadata for explicit registration unless discovery is enabled.

Discovery is opt-in:

```ruby
contracts = Igniter::Embed.configure(:shop) do |config|
  config.root "app/contracts"
  config.discover!
end
```

By default discovery requires `**/*_contract.rb` under `config.root` and
registers newly loaded, named `Class < Igniter::Contract` definitions by
inferred name. Anonymous contract classes are ignored by discovery and must be
registered explicitly with `as:` if you want to call them through the host.

Prefer explicit `config.contract` for application boot paths where stable
naming matters. If explicit registration and discovery produce the same name,
the explicit registration wins. If two discovered classes infer the same name,
discovery raises `Igniter::Embed::DiscoveryError` and asks you to register them
explicitly.

Rails integration is optional:

```ruby
require "igniter/embed/rails"

Igniter::Embed::Rails.install(
  contracts,
  reloader: Rails.application.reloader,
  cache: !Rails.env.development?
)
```

The Rails adapter only connects host reload callbacks to `container.reload!`.
The base package remains Rails-free.

## Contractable Shadowing

`igniter-contracts` owns the core `Contractable` service protocol used by
`compute using:`. The `igniter-embed` `contractable` API below is a host
wrapper for migration, shadowing, discovery, and production observation.

`contractable` wraps host services without changing their public API. The
primary callable runs synchronously and its raw result is returned; an optional
candidate can run through a shadow adapter, normalize outputs, compare through
`DifferentialPack`, and record an observation through an app-supplied store.
When `async` is true, the default adapter uses a local Ruby thread so candidate
work does not block the primary response. It is not a durable production job
queue; provide an app adapter for ActiveJob, Sidekiq, or another backend when
durability matters.

When a primary or candidate is a core `Igniter::Contracts::Contractable`
service, embed invokes it through the core protocol and adopts its declared
`role`, `stage`, and metadata as wrapper defaults unless the wrapper explicitly
overrides them.

```ruby
QuoteShadow = Igniter::Embed.contractable(:quote) do |config|
  config.role :migration_candidate
  config.stage :shadowed
  config.primary LegacyQuote
  config.candidate ContractQuote
  config.normalize_primary QuoteNormalizer
  config.normalize_candidate QuoteNormalizer
  config.accept :shape, outputs: { total: Numeric, status: String }
  config.store QuoteObservationStore
end

result = QuoteShadow.call(amount: 100)
```

The same shape can be declared through host sugar. This keeps registration,
shadow migration intent, adapters, and event hooks in one inspectable
initializer:

```ruby
contracts = Igniter::Embed.host(:billing) do
  contracts do
    add :price_quote, Billing::PriceContract do
      migrate Billing::LegacyQuote, to: Billing::ContractQuote
      shadow async: false, sample: 1.0

      use :normalizer, Billing::QuoteNormalizer
      use :redaction, only: %i[amount customer_id]
      use :acceptance, policy: :shape, outputs: { total: Numeric }
      use :store, Billing::ObservationStore

      on :divergence do |event|
        Billing.logger.warn(event)
      end
    end
  end
end

runner = contracts.contractable(:price_quote)
runner.call(amount: 100, customer_id: "cust_1", token: "secret")
```

Generated contractable runners are host-local:

```ruby
contracts.contractable_names
contracts.fetch_contractable(:price_quote)
contracts.sugar_expansion.to_h
```

`on :failure` is an alias family for typed failure events:
`:primary_error`, `:candidate_error`, `:acceptance_failure`, and
`:store_error`. Divergence is intentionally separate and should be subscribed
to with `on :divergence`.

Capability attachment sugar exists for host-owned targets. It does not install
implicit built-ins:

```ruby
contracts = Igniter::Embed.host(:billing) do
  contracts do
    add :price_quote, Billing::PriceContract do
      migrate Billing::LegacyQuote, to: Billing::ContractQuote
      use :normalizer, Billing::QuoteNormalizer

      use :logging, contract: Billing::LogObservationContract
      use :reporting, ->(event) { Billing.reporter.record(event) }
      use :metrics, target: Billing::MetricsSink
      use :validation, callable: Billing::ObservationValidator
    end
  end
end
```

Each explicit target appears in `sugar_expansion` as either `kind: :contract`
or `kind: :callable_adapter`.

Primary-only observed services use the same surface:

```ruby
ObservedQuote = Igniter::Embed.contractable(:quote) do |config|
  config.role :observed_service
  config.primary LegacyQuote
  config.normalize_primary QuoteNormalizer
  config.store QuoteObservationStore
end
```

For an observed service, the normalizer should return a redacted aggregate
summary. The primary callable remains authoritative and its raw result is still
returned to the host app.

```ruby
AvailabilityObserver = Igniter::Embed.contractable(:availability) do |config|
  config.role :observed_service
  config.stage :captured
  config.primary AvailabilityService
  config.normalize_primary AvailabilitySummaryNormalizer
  config.redact_inputs ->(**inputs) { inputs.slice(:request_ref, :window_ref) }
  config.store AvailabilityObservationStore
end

class AvailabilitySummaryNormalizer
  def self.call(_result)
    {
      status: :ok,
      outputs: {
        status: "success",
        receipt_kind: "availability_slot_map_summary",
        redaction_policy: "availability_slot_map_summary_v1",
        availability_bucket: "available",
        dominant_unavailable_state: "day_off",
        available_ratio: 0.75,
        total_slots: 4,
        available_slots: 3,
        scheduled_slots: 0,
        off_schedule_slots: 0,
        day_off_slots: 1,
        past_slots: 0
      },
      metadata: { normalizer: :availability_summary_v1 }
    }
  end
end
```

The aggregate payload above is a sanitized normalizer example. It becomes part
of `receipt[:primary][:outputs]`; it is not the top-level Embed receipt
envelope. In particular, `"availability_slot_map_summary"` is fixture/example
vocabulary for the aggregate output shape, not an `igniter-embed` receipt kind.
The Embed observation receipt that contains it still uses
`receipt_kind: :contractable_observation`, and event receipts still use
`receipt_kind: :contractable_event`.

Keep this shape host-local:

- choose the observed target, rollout flag, and sample rate in the app;
- keep the redaction allow-list app-owned;
- persist receipts through an app-owned store adapter;
- treat Ledger sinks as optional adapters, not as the source of truth;
- do not infer release readiness or a public schema from synthetic aggregate
  examples.

## Observation Receipts

Each contractable call produces a canonical observation receipt. The receipt
includes a stable `observation_id`, `schema_version`, `receipt_kind`, and a
`status` that summarises the outcome:

```text
:ok               — primary and candidate matched and were accepted
:diverged         — outputs diverged but acceptance policy passed
:candidate_error  — candidate raised an exception
:acceptance_failed — candidate succeeded but acceptance policy failed
:store_error      — store adapter raised after primary returned
:unsampled        — call was outside the configured sample rate
```

A Spark-style store adapter wires receipts into a durable sink:

```ruby
class SparkObservationStore
  def record_observation(receipt)
    # receipt[:observation_id]  — stable id for linking to logs/admin
    # receipt[:status]          — :ok | :diverged | :candidate_error | …
    # receipt[:redaction]       — policy applied to inputs
    ObservationRecord.create!(receipt.slice(:observation_id, :status, :name, :role, :stage).merge(payload: receipt))
  end

  def record_event(receipt)
    # receipt[:receipt_kind]  == :contractable_event
    # receipt[:event_id]      — unique per event
    # receipt[:observation_id] — links back to the observation
    # receipt[:severity]      — :info | :warning | :error
    return unless receipt[:severity] == :error || receipt[:event] == :divergence

    ObservationEvent.create!(receipt.slice(:event_id, :observation_id, :event, :severity, :summary))
  end
end
```

Register the store in a host:

```ruby
runner = Igniter::Embed.contractable(:marketing_executor) do
  migrate Api::Marketing::ExecutorService::Legacy,
          to: Api::Marketing::ExecutorService::Contract
  shadow async: true, sample: 0.1
  use :normalizer, Api::Marketing::ExecutorNormalizer
  use :redaction, only: %i[provider_payload technician_id customer_id]
  use :acceptance, policy: :shape, outputs: { status: String, result: Hash }
  use :store, SparkObservationStore.new

  on :divergence do |event|
    Rails.logger.warn("[igniter] divergence obs=#{event.dig(:receipt, :observation_id)}")
  end
end
```

A divergence event payload includes a compact receipt:

```ruby
{
  event: :divergence,
  receipt: {
    schema_version: 1,
    receipt_kind: :contractable_event,
    event_id: "evt_...",
    observation_id: "obs_...",
    severity: :warning,
    summary: "outputs diverged from primary",
    observation_ref: { observation_id: "obs_...", match: false, accepted: false }
  }
}
```

Async adapters receive a handoff descriptor for durable job wiring:

```ruby
class SidekiqObservationAdapter
  def enqueue(name:, inputs:, metadata:, handoff: nil, &block)
    if handoff
      ObservationJob.perform_later(
        observation_id: handoff[:observation_id],
        name: handoff[:name],
        queued_at: handoff[:queued_at]
      )
    else
      # fallback: run inline
      block.call
    end
  end
end
```
