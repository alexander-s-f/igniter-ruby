---
name: idd-agent-protocol
description: Design, simplify, and apply lightweight agent work protocols using Igniter Driven Development principles. Use when Codex needs to choose the right process weight, artifact, handoff, report packet, cross-project letter, role/lens/authority boundary, or multi-agent workflow; when adapting Igniter-Lang-style governance without copying excess ceremony; or when turning ambiguous agent/process work into compact receipts, cards, tracks, reports, or gate decisions.
---

# IDD Agent Protocol

Use this skill to keep agent work legible without turning it into process noise. Treat it as an artifact router and authority guard: choose the smallest useful workflow, state the boundary, preserve evidence, and escalate only when risk or cross-project meaning requires it.

## IDD Axioms

Apply these before choosing any template:

1. Contract before ceremony.
   Name the contract, boundary, or question before creating process around it.

2. Authority is not evidence.
   Logs, dry-runs, shadows, reports, reviews, and receipts inform decisions; they do not become authority by themselves.

3. Use the smallest artifact that prevents drift.
   Prefer: chat receipt < doc note < cross-project letter < track < report packet < gate decision.

4. Preserve local truth.
   Each project keeps its own product semantics. Reconcile meanings deliberately through adapters, not premature unification.

5. Observe before switching authority.
   Prefer shadow, dry-run, compare, observe, and human review before changing production behavior.

6. Roles clarify responsibility, not hierarchy.
   A role or borrowed lens changes what an agent should notice; only explicit authorization changes what it may decide or implement.

7. Stop when structure stops buying clarity.
   If the next artifact creates status noise instead of reducing ambiguity, use a smaller receipt or no artifact.

## Quick Workflow

1. Classify the work:
   - `fast_lane`: small fix, quick diagnosis, UI check, docs cleanup, narrow spike.
   - `standard`: multi-step feature, domain research, medium refactor, durable knowledge.
   - `formal`: migrations, production ops, release, billing/vendor/ledger authority, protected data, destructive operations.
   - `cross_project`: product meaning, API shape, ID mapping, auth/deploy facts, shared vocabulary, or partner dependency.

2. State the authority surface:
   - current authority;
   - evidence source;
   - allowed changes;
   - closed surfaces.

3. Pick the smallest artifact:
   - Use a chat receipt for fast-lane work.
   - Update an existing durable doc for domain knowledge.
   - Write an inbox/outbox letter for cross-project meaning.
   - Create a track when work needs durable step evidence.
   - Create a report packet only for round closure, Portfolio/cross-lane decisions, or formal acceptance.
   - Create a gate decision only when an authority boundary must change.

4. Execute inside scope, then close with evidence and next route.

## Mode Selection

Use `references/modes-and-artifacts.md` when the user asks for a protocol, card, operating model, report packet, or when process weight is unclear.

Use `references/templates.md` when producing a concrete artifact.

For observation-heavy slices, prefer the compact `Evidence Decision Next
Contract` template. For SparkCRM production read-only checks, prefer the `Spark
MCP Observe Receipt` template.

Use `references/source-patterns.md` when borrowing from Igniter-Lang or SparkCRM patterns, or when explaining why the protocol is strict or lightweight.

## Authority Checks

Before changing code, docs, data, or process, ask internally:

```text
What decides behavior today?
What is only evidence?
What is explicitly authorized?
What remains closed?
Who owns product meaning?
Who owns code/data evidence?
What artifact is enough to prevent drift?
```

Hold or ask for a narrower card when implementation would cross a protected surface without authorization.

## Card Hygiene

When producing cards for copy/paste dispatch:

- Put the entire dispatchable card inside one fenced `text` block.
- The `Card:` line must be inside the fence, not above it.
- Keep card lines reasonably wrapped so agents do not lose track structure.
- Add `Skill: <skill name>` only when a specific skill materially changes the
  protocol, authority boundary, or expected artifact shape.
- Do not add skill markers to every card by default; markers should reduce
  drift, not become ceremony.

## Anti-Patterns

Avoid:

- creating cards, reports, or route tables by default;
- making every small task durable;
- treating a review, discussion, dry-run, report, or shadow path as authority;
- hiding blockers inside long narrative docs;
- letting partner code shape become product ontology without product review;
- forcing one project's vocabulary onto another project too early;
- copying Igniter-Lang governance where a SparkCRM-style fast-lane receipt is enough.

## Output Style

Keep outputs compact and decision-friendly. Prefer concrete artifacts over meta-explanation once the mode is clear. If the user is still shaping the methodology, discuss the tradeoffs first, then write the artifact after alignment.
