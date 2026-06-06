# igniter-application

Clean-slate contracts-native local application runtime for Igniter.

This package is intentionally separate from `igniter-app`.

- `igniter-application` is the new target package for local app assembly/runtime
- `igniter-app` remains a frozen legacy/reference package during the reset

Primary entrypoints:

- `require "igniter-application"`
- `require "igniter/application"`

Primary API:

- `Igniter::Application.build_kernel`
- `Igniter::Application.build_profile`
- `Igniter::Application.with`
- `Igniter::Application::Kernel`
- `Igniter::Application::Profile`
- `Igniter::Application::Environment`
- `Igniter::Application::ApplicationBlueprint`
- `Igniter::Application::ApplicationManifest`
- `Igniter::Application::ApplicationLayout`
- `Igniter::Application::ApplicationStructurePlan`
- `Igniter::Application::ApplicationStructureEntry`
- `Igniter::Application::MountRegistration`
- `Igniter::Application::Snapshot`
- `Igniter::Application::BootPlan`
- `Igniter::Application::BootReport`
- `Igniter::Application::PlanExecutor`
- `Igniter::Application::ShutdownPlan`
- `Igniter::Application::ShutdownReport`
- `Igniter::Application::SeamLifecycleResult`
- `Igniter::Application::CredentialStore`
- `Igniter::Application::MissingCredentialError`
- `Igniter::Application::AIRegistry`
- `Igniter::Application::AgentRegistry`
- `Igniter::Application.file_backed_installed_capsule_registry`
- `Igniter::Application.record_installed_capsule`

AI providers are configured at the application layer and resolved through the
environment. Applications declare intent; provider-specific client construction
stays under `igniter-ai`:

```ruby
environment = Igniter::Application.build_kernel
                                  .credential(:openai_api_key, env: "OPENAI_API_KEY")
                                  .ai do
                                    provider :openai,
                                             credential: :openai_api_key,
                                             model: "gpt-5.2"
                                  end
                                  .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

client = environment.ai_client(:openai)
```

Agents are configured the same way: applications declare named assistants,
while `igniter-agents` owns run/turn/trace state.

```ruby
environment = Igniter::Application.build_kernel
                                  .ai do
                                    provider :summary, :fake, text: "Ready."
                                  end
                                  .agents do
                                    assistant :daily_companion,
                                              ai: :summary,
                                              instructions: "Give one next action."
                                  end
                                  .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

run = environment.agent(:daily_companion).run(input: "Two reminders are open.")
```

Installed capsule state is receipt-backed application state. A catalog or hub
can point at a transfer bundle, but the application records what actually
landed:

```ruby
registry = Igniter::Application.file_backed_installed_capsule_registry(root: "tmp/igniter")
entry = Igniter::Application.record_installed_capsule(
  :horoscope,
  receipt: transfer_receipt,
  registry: registry,
  source: "local-hub",
  version: "0.1.0"
)

entry.installed? #=> true when the transfer receipt is complete
```

The file-backed registry keeps current state and append-only history separate:
`registry.fetch(:horoscope)` returns the latest entry, while
`registry.history(:horoscope)` returns every recorded install attempt in
sequence order.

Credentials are app runtime configuration for secrets such as API keys. They
are fetched explicitly at runtime and redacted from manifests/profile payloads:

```ruby
environment = Igniter::Application.build_kernel
                                  .credential(:openai_api_key, env: "OPENAI_API_KEY")
                                  .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }

environment.credentials.configured?(:openai_api_key)
environment.credentials.fetch(:openai_api_key)
```

See [Credentials](../../docs/guide/credentials.md).

The application layer also now owns a first local session seam for durable
host-side orchestration around contracts-native compose/collection flows:

The user application model now has a first explicit shape too:

- `ApplicationBlueprint` describes an intended app structure before files are
  written or a runtime profile is finalized
- `ApplicationLayout` supports named profiles: `:standalone`, `:capsule`, and
  `:expanded_capsule`
- `ApplicationBlueprint` can publish capsule `exports:` and `imports:` as
  manifest portability metadata
- `ApplicationStructurePlan` inspects and explicitly materializes missing
  layout paths from a blueprint without becoming a legacy scaffold generator
- sparse structure plans materialize only active groups; complete plans
  materialize every known group
- `ApplicationManifest` captures app name, root, env, packs, contracts,
  providers, services, mounts, config, and layout
- `ApplicationLayout` captures canonical user-app paths such as
  `app/contracts`, `app/providers`, `app/services`, `app/effects`,
  `app/packs`, `config/igniter.rb`, and `spec/igniter`
- `Kernel#manifest(...)` configures the app identity and root before finalize
- `Environment#manifest` and `Environment#layout` expose the finalized shape
- `Kernel#mount` and `Kernel#mount_web` register generic mounted interaction
  surfaces without depending on `igniter-web` classes
- the default `ManualLoader` returns an `ApplicationLoadReport` during boot,
  including present and missing layout paths

- configurable `session_store` seam on `Application::Kernel`
- default `MemorySessionStore`
- `FlowSessionSnapshot`, `FlowEvent`, `PendingInput`, `PendingAction`, and
  `ArtifactReference` for agent-native interaction session snapshots
- `Environment#start_flow`
- `Environment#resume_flow`
- `Environment#run_compose_session`
- `Environment#run_collection_session`
- `Environment#compose_invoker`
- `Environment#collection_invoker`
- `Environment#remote_compose_invoker`
- `Environment#remote_collection_invoker`
- `Environment#fetch_session`
- `Environment#sessions`

That keeps local session durability in `igniter-application`, while the actual
graph semantics still live in `igniter-contracts` and `igniter-extensions`.

Remote execution is still not a cluster layer here; these helpers only define a
transport-ready adapter seam over the same session model. Real routing,
placement, and distributed coordination should arrive later in
`igniter-cluster`.

Provider lifecycle is explicit:

- provider registry resolution is separate from provider `boot`
- `Environment#boot` returns provider resolution and provider boot reports
- `Environment#shutdown` returns a provider shutdown report

Host-owned seam lifecycle is explicit too:

- loader `load`
- scheduler `start` / `stop`
- host transport `activate` / `deactivate`

These seams are reported as structured lifecycle results inside
`BootReport`, `ShutdownReport`, and `Snapshot`.

Boot and shutdown can also be planned explicitly before execution:

- `Environment#plan_boot`
- `Environment#plan_shutdown`
- `Environment#execute_boot_plan`
- `Environment#execute_shutdown_plan`

That gives tooling and hosts a stable pre-execution shape for local lifecycle
decisions without introducing cluster semantics into `Application`.

That keeps `igniter-application` local-first and explainable, while still
leaving room for richer remote or mesh-specific execution layers above it.

First clean external host adapter:

- `Igniter::Server::ApplicationHost`
