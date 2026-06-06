## [Unreleased]

## [0.4.0] - 2026-04-09

### Added

- **igniter-stack** — standalone HTTP service for hosting contracts over the network
  - `Igniter::Server.start` — blocking pure-Ruby TCPServer; zero external dependencies
  - `Igniter::Server.rack_app` — Rack-compatible adapter for Puma/Unicorn
  - `Igniter::Server.configure { |c| c.port = 4567; c.register "Name", MyContract }`
  - CLI: `bin/igniter-stack start --port 4567 --require ./contracts.rb`
  - REST API: `POST /v1/contracts/:name/execute|events`, `GET /v1/executions/:id|health|contracts`
  - `Igniter::Server::Client` — HTTP client (Net::HTTP + JSON, stdlib only)
  - `Igniter::Server::Registry` — thread-safe contract name → class mapping
- **`remote:` DSL keyword** — call a contract on a remote igniter-stack from inside a graph
  - `remote :result, contract: "OtherContract", node: "http://host:4568", inputs: { raw: :data }`
  - Validated at compile time (URL format, dependency resolution, contract name)
  - Raises `Igniter::ResolutionError` on connection failure or remote contract failure
- **LLM Anthropic provider** — `Igniter::LLM::Providers::Anthropic`
  - System prompt sent as top-level field; content blocks array; `input_schema` for tool definitions
  - Reads `ANTHROPIC_API_KEY` from ENV; configurable via `Igniter::LLM.configure`
- **LLM OpenAI provider** — `Igniter::LLM::Providers::OpenAI`
  - Compatible with OpenAI, Groq, Mistral, DeepSeek, and Azure OpenAI
  - Reads `OPENAI_API_KEY` from ENV

---

## [0.3.1] - 2026-03-19

- Add DX-oriented DSL helpers `project` and `aggregate` for compact extraction and summary nodes.
- Extend `branch` and `collection` with `map_inputs:` and named `using:` mappers to reduce orchestration wiring noise.
- Allow `collection` mapper mode to iterate over hash-like sources directly without a preparatory `to_a` node.
- Add diagnostics-only output presenters via `present` for compact human-facing summaries without changing raw machine-readable outputs.
- Improve diagnostics formatting for nested branch/collection outputs and clean up inline value rendering for hashes and symbol-heavy summaries.
- Validate and exercise the new DX surface against private production-like scheduler migration POCs.

## [0.3.0] - 2026-03-19

- Add executor metadata and global executor registry for self-describing, schema-friendly execution steps.
- Split compiler validation into a pluggable validation pipeline and add shared type compatibility checks.
- Introduce planner/runner runtime architecture with `:inline`, `:thread_pool`, and store-backed execution modes.
- Add deferred nodes, pending state, snapshot/restore, token-based resume, worker-style resume flow, and reference file/ActiveRecord/Redis store adapters.
- Expand the DSL with `with`, matcher-style `guard`, `scope`, `namespace`, `branch`, `collection`, `expose`, `on_failure`, and `on_exit`.
- Add `branch` and `collection` as graph primitives with compile-time validation, nested runtime support, and item-level collection events.
- Improve diagnostics and auditing with collection summaries, partial-failure visibility, item-level failure reporting, and richer markdown/text output.
- Add production-like runnable examples for async resume, ergonomic domain contracts, collection partial failure, and nested branch + collection routing.
- Add design docs for branches, collections, store adapters, and orchestration patterns.

## [0.2.0] - 2026-03-18

- Complete the `arbor` to `igniter` rename across runtime, docs, examples, console setup, and shipped signatures.
- Strengthen compile-time validation for proc signatures, composition input mappings, node ids, and node paths.
- Refine runtime semantics with a dedicated invalidation object, stricter execution lifecycle events, and explicit `execution_failed` signaling.
- Make composition resolution eager and reliable so parent composition nodes fail when child executions fail.
- Add structured error context with graph, node, path, and source location metadata.
- Expand introspection with stable node ids, invalidation details, richer explain output, and machine-readable execution/result/event payloads.
- Add diagnostics reports with structured, text, and markdown summaries for successful and failed executions.
- Add runnable example scripts plus smoke-tested quick-start examples and refresh the public documentation.

- Rename the gem and top-level namespace from `arbor` to `igniter`.
- Replace the legacy prototype with the v2 core runtime, compiler, DSL, and extensions.
- Add typed inputs, composition, auditing, reactive subscriptions, and introspection.

## [0.1.0] - 2025-08-03

- Initial release
