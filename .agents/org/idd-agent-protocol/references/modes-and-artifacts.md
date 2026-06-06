# Modes And Artifacts

Use this reference to choose process weight and artifact shape.

## Decision Table

| Mode | Use for | Artifact | Exit |
| --- | --- | --- | --- |
| Soft / Fast Lane | Small fixes, quick diagnosis, UI checks, docs cleanup, narrow spikes | Chat receipt, or no durable artifact | Goal, changed/found, verified, risks/next |
| Standard / IDD Card | Multi-step feature work, domain research, medium refactor, durable knowledge | Existing doc update, short track, changelog, or domain note | Boundary, evidence, decision, next route |
| Cross-Project Letter | Product semantics, IDs, API shape, auth/deploy facts, shared vocabulary | `inbox`/`outbox` letter or compact sync slice | Product answer and code/data answer are separated |
| Formal / Controlled Flow | Migrations, production ops, billing/vendor/ledger authority, release, protected data, destructive work | Explicit plan, track, acceptance packet, report packet, or gate decision | Verification, observe/rollback notes, closed surfaces |

## Escalation Triggers

Escalate from fast lane to standard or formal when the work touches:

- credentials, tokens, production data, paid APIs, or MCP production access;
- database migrations, backfills, destructive data operations, or irreversible cleanup;
- billing, vendor authority, telephony authority, ledger authority, release flow, deploy state;
- public API contracts, partner integrations, cross-project IDs, auth, or pricing semantics;
- a decision that changes who or what is allowed to decide business behavior.

## Artifact Router

Use the smallest artifact that prevents drift:

```text
small local fix -> chat receipt
durable domain rule -> domain doc
repeated foundation context -> readme/foundation note
partner/internal project question -> outbox letter
partner/internal project answer -> inbox letter
multi-step evidence -> track
round closure or cross-lane decision -> report packet
authority change -> gate decision or explicit authorization card
```

## Authority Levels

Interpret outputs by authority level:

| Output | Authority |
| --- | --- |
| Chat receipt | Local closure note; not durable canon by default |
| Discussion | Pressure only; never canon by itself |
| Review | Signal requiring intake or routing |
| Dry-run / shadow / compare | Evidence; not production authority |
| Track | Evidence for a bounded slice |
| Proposal / design card | Candidate direction until accepted |
| Report packet | Closure/read-order artifact; not implementation authorization |
| Gate decision | Explicit authority boundary change when issued by the owner |

## Role / Lens / Authority

Use roles to narrow attention, not to grant power.

```text
Role = responsibility and ownership
Lens = temporary viewpoint
Authority = what the agent may decide or change
Card = current task contract
Handoff = evidence and next route
```

If an agent is in the wrong chat or wrong role, it may execute a self-contained non-authority card under the assigned card role. For authority decisions, it should return a recommendation packet unless explicitly initialized as the authority owner.

## Product Semantics And Code Facts

When product meaning and implementation evidence both matter, separate them:

```text
Product answer:
- intended meaning, user workflow, business rule, ontology

Code/data answer:
- current code behavior, payload shape, tests, deploy state, observed data
```

Do not let accidental code shape become product ontology without review.
