# igniter-ai

Provider-neutral AI execution for Igniter.

Status: first package slice, not stable API.

## Owns

- model request/response envelopes
- provider clients
- fake, live, and recorded execution modes
- response text, usage, metadata, and error normalization
- replay seams for examples and tests

## Does Not Own

- agent loops
- application boot/configuration
- web rendering
- MCP transport

## Example

```ruby
require "igniter-ai"

client = Igniter::AI.client(
  provider: Igniter::AI::Providers::Fake.new(text: "Ready.")
)

response = client.complete(
  model: "fake",
  instructions: "Summarize the day.",
  input: "Two reminders are open."
)

response.success? # true
response.text     # "Ready."
```

Live providers are opt-in by application configuration. Default specs and
examples should use fake or recorded providers.
