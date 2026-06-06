# Source Patterns

This skill borrows selectively from Igniter-Lang and SparkCRM agent practices.
Use these notes as design memory, not as project-specific authority.

## Igniter-Lang Pattern

Use when work is research-heavy, compiler/language-facing, release-facing, multi-agent, or authority-sensitive.

Stable core:

```text
Role + Context + Card + Lens + Authority + Route
```

What to preserve:

- separate agent identity from role profile;
- distinguish discussion, review, track, proposal, report, and gate decision;
- keep current context as a map, not a full history;
- treat pressure/review as signal, not canon;
- require explicit authorization for protected surfaces;
- end slices with compact handoff and next route.

What to soften outside strict work:

- do not require broad onboarding reads for every small task;
- do not create tracks/reports by default;
- do not duplicate status across many files when one receipt is enough;
- do not let card codes obscure the actual goal and boundary.

## SparkCRM Pattern

Use when work is inside a production app and needs speed without losing safety.

Stable core:

```text
lightest process that protects the work
```

What to preserve:

- fast lane is legitimate for small safe work;
- `.agents` is a map, not an archive;
- legacy behavior remains authority until replacement is proven;
- use shadow, dry-run, compare, observe, and manager/human review before authority switch;
- route durable domain knowledge to docs, operational breadcrumbs to changelog/release notes, and cross-project meaning to inbox/outbox letters;
- protect credentials, production data, migrations, paid APIs, billing/vendor/ledger authority, release, git history, and uncommitted user work.

## Shared IDD Philosophy

Use these as portable rules:

- name the contract before broad implementation;
- separate authority from evidence;
- keep source identity and mappings explicit;
- prefer append-only or auditable facts for important business changes;
- normalize bundles into atomic candidates before ledger or authority decisions when ambiguity would otherwise become history;
- carry product semantics and code evidence separately;
- stop when the next artifact creates ceremony instead of clarity.

## Practical Synthesis

Choose strictness by risk:

```text
low risk + local -> fast lane receipt
medium risk or durable knowledge -> IDD card/doc note
cross-project semantics -> short letter
protected surface -> formal controlled flow
authority change -> gate decision
```
