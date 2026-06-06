# igniter-ledger Docs Workflow

Status date: 2026-05-03
Status: active working convention
Owner: [Architect Supervisor / Codex]

## Purpose

Keep `igniter-ledger` documentation useful while the package moves quickly before
v1. Not every note deserves to live forever in the top-level docs list.

## Flow

```text
research/
  raw investigation, exploratory notes, design history

proposals/
  candidate architecture that needs decision

tracks/
  accepted implementation slices with owner, scope, acceptance, handoff

final docs
  stable-enough package docs linked from README specifications

old / complete
  move to playgrounds/docs or compact into progress when no longer useful
```

## Current Transitional Rule

The package already has many top-level docs. Do not churn everything at once.
For new work:

- Put exploratory horizons in `docs/research/` or a named research directory.
- Put decision candidates in `docs/proposals/`.
- Put executable agent work slices in `docs/tracks/`.
- Promote only stable, useful package docs to the top-level README table.
- When a doc is superseded, compact it into `progress.md` or move it to
  `playgrounds/docs` instead of keeping stale instructions near active work.

## Handoff Shape For Tracks

Every track doc should include:

- status date
- owner / agent
- goal
- scope
- non-goals
- acceptance
- tests expected
- handoff format

## Package Agent Rule

Package Agent should receive `tracks/` documents, not broad research notes. A
track should be one large vertical slice that can be completed, tested, and
handed back in a compact packet.

For fresh Package Agent chats, use `docs/package-agent-onboarding.md` as the
first read, then `docs/progress.md`, then exactly one assigned track. This keeps
token pressure bounded after large completed slices.
