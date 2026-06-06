# igniter-mcp-adapter

Thin MCP adapter package over Igniter's tooling-facing contracts surfaces.

This package exists to keep transport and server concerns separate from the
tooling semantics that live in `igniter-extensions`.

## Purpose

- expose the stabilized MCP-oriented tool catalog
- delegate tool invocation to `Igniter::Extensions::Contracts::McpPack`
- keep transport/runtime concerns out of `igniter-extensions`

## What This Package Should Not Do

- define new creator or debug semantics
- reach into `igniter-contracts` internals directly
- become a second source of truth for tool behavior

## Public Surface

```ruby
require "igniter-mcp-adapter"

catalog = Igniter::MCP::Adapter.tool_catalog
result = Igniter::MCP::Adapter.invoke(:creator_session_start, name: :delivery)
```

Transport-ready server wrapper:

```ruby
tool = Igniter::MCP::Adapter::Server.tool(:creator_session_apply)

response = Igniter::MCP::Adapter::Server.call(
  :creator_session_start,
  arguments: { name: "delivery", capabilities: %w[effect executor] }
)
```

JSON-RPC stdio host entrypoint:

```ruby
host = Igniter::MCP::Adapter::Host.new
host.serve
```

The package also ships an executable:

```bash
igniter-mcp-adapter
```

## Boundary

`igniter-mcp-adapter` depends on `igniter-extensions` only. The semantic source
of truth remains:

- `Igniter::Extensions::Contracts.mcp_tools`
- `Igniter::Extensions::Contracts.mcp_call(...)`
- `Igniter::Extensions::Contracts.mcp_creator_session(...)`

## Docs

- [Igniter Ruby Docs](../../docs/README.md)
- Package-local README files are the active split-era package docs.
