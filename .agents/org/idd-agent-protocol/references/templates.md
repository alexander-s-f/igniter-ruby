# Templates

Use these templates as starting points. Keep only fields that reduce ambiguity for the current task.

## Fast Lane Receipt

```text
Fast Lane Receipt:
- Goal:
- Changed / Found:
- Verified:
- Risks / Follow-up:
```

## Minimal IDD Card

```text
# <Card / Track Name>

Status: draft | active | done | held
Route: fast_lane | standard | formal | cross_project

## Goal

One concrete question or movement.

## Current Authority

- decides behavior today:
- evidence available:

## Boundary

Allowed:
- ...

Closed:
- ...

## Plan

- ...

## Verification / Evidence

- files:
- commands/tests:
- logs/MCP/observe:
- human confirmation:

## Decision / Next

- accepted / conditional / held / redirected:
- next route:
```

## Compact Handoff

```text
Status:
Claim:
Evidence:
Changed files:
Risks / drift:
Cross-lane requests:
Next:
```

## Evidence Decision Next Contract

Use when a slice is mostly observation, audit, analytics, or shadow/dry-run
pressure and the goal is to decide the next bounded contract without changing
authority.

```text
Evidence:
- source:
- window / scope:
- strongest facts:
- missing / ambiguous:

Decision:
- pass / conditional / hold / redirect:
- why:
- what is evidence only:
- what remains authority:

Next contract:
- card / doc / no artifact:
- allowed:
- closed:
- verification:
```

Keep it short. If this grows into round closure, promote to a report packet. If
it authorizes behavior change, promote to a gate decision.

## Spark MCP Observe Receipt

Use for SparkCRM read-only production observation through MCP/admin reports.

```text
Spark MCP Observe Receipt:
- Goal:
- MCP tools:
- Window / filters:
- Key counts:
- Top rows / anomalies:
- Fresh errors:
- Human/admin confirmation:
- Decision:
- Next:
- Closed surfaces:
```

Rules:

- MCP output is evidence, not authority.
- Do not expose credentials, raw customer/contact payloads, or raw phone data in
  shared docs.
- Prefer grouped/count evidence for manager-facing notes.
- If an admin route is behind authentication, unauthenticated HTTP checks are
  not valid page-render proof; use human/admin browser confirmation.
- Keep writes, seed/reseed, backfills, routing, API, billing/vendor/ledger
  authority closed unless explicitly authorized.

## Cross-Project Letter

```markdown
# <Project> <Question / Sync Slice>

Date:
From:
To:
Route: cross-project clarification | sync slice | return packet

## Goal

What decision or alignment this unlocks.

## Why We Are Asking

- ...

## Product Questions

For product owner / designer:
- ...

## Code / Data Questions

For developer / project agent:
- ...

## Current Hypothesis

- ...

## Desired Return Packet

- product answer:
- code/data answer:
- mismatch between intent and implementation:
- recommended MVP contract:
- explicitly not authorized:

## Boundaries

Do not:
- ...
```

## Report Packet

Use for formal closure or Portfolio/cross-lane read order, not for every task.

```markdown
# Round Report: <lane / round / topic>

Status: done | partial | blocked
Date:
Supervisor / Owner:
Scope:

## Executive Summary

- 3-7 bullets only.

## Decisions Needed

- [ ] ...

## Completed

- ...

## Changed Files

- ...

## Evidence

- tracks:
- gates:
- discussions:
- tests/proofs:
- observe/MCP/human confirmation:

## Risks / Drift

- ...

## Cross-Lane Requests

To <lane/project>:
- ...

## Recommended Next

- ...
```

## Gate / Authority Decision

```markdown
# <Authority Decision>

Status: accepted | held | rejected | conditional
Owner:
Scope:

## Evidence Read

- ...

## Decision

- ...

## Authorized

- exact write/behavior surface:
- exact next card:

## Still Closed

- ...

## Verification Required

- ...

## Next

- ...
```
