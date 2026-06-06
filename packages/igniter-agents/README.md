# igniter-agents

Minimal agent runtime state for Igniter.

Status: first package slice, not stable API.

## Owns

- agent definitions
- agent runs, turns, and trace events
- single-turn assistant execution over `igniter-ai`
- serializable run state for app/web rendering

## Does Not Own

- provider-specific HTTP clients
- application boot/configuration
- web rendering
- distributed scheduling

## Example

```ruby
require "igniter-agents"

client = Igniter::AI.client(
  provider: Igniter::AI::Providers::Fake.new(text: "Close one reminder.")
)

agent = Igniter::Agents.agent(
  :daily_companion,
  model: "fake",
  instructions: "Give one practical next action."
)

run = Igniter::Agents.run(agent, ai_client: client, input: "Two reminders are open.")

run.success?          # true
run.turns.first.text  # "Close one reminder."
run.to_h              # serializable state for apps and web
```

Future slices should add contracts-first tool calls, memory, handoff, and human
gates without moving provider or web concerns into this package.
