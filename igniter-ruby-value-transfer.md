# igniter-ruby Value Transfer Map

Status: rough value-positive map / underfill preferred / no physical transfer yet
Date: 2026-06-06

## Principle

This repo should receive the Ruby Framework and package umbrella. It should
not inherit Igniter Lang semantic authority. Language references should become
cross-links or adapter docs, not embedded language canon.

Path notation:
- source paths are relative to `projects/`
- target paths are relative to `igniter-workspace/`

## Bring First

| Source | Target | Why |
| --- | --- | --- |
| `igniter/README.md` | `igniter-workspace/igniter-ruby/README.md` | Ruby framework entrypoint; rewrite to remove language-root ambiguity. |
| `igniter/AGENTS.md` | `igniter-workspace/igniter-ruby/AGENTS.md` | Ruby framework agent instructions. |
| `igniter/LICENSE.txt` | `igniter-workspace/igniter-ruby/LICENSE.txt` | Package/legal surface. |
| `igniter/CODE_OF_CONDUCT.md` | `igniter-workspace/igniter-ruby/CODE_OF_CONDUCT.md` | Community surface if retained. |
| `igniter/CHANGELOG.md` | `igniter-workspace/igniter-ruby/CHANGELOG.md` | Ruby framework release history. |
| `igniter/Gemfile`, `igniter/Gemfile.lock` | target root | Ruby framework dev dependencies. |
| `igniter/Rakefile` | target root | Ruby framework tasks. |
| `igniter/.rubocop.yml` | target root | Ruby lint posture. |
| `igniter/igniter.gemspec` | target root | Root gem/package metadata. |
| `igniter/lib/` | `igniter-workspace/igniter-ruby/lib/` | Ruby framework implementation. |
| `igniter/sig/` | `igniter-workspace/igniter-ruby/sig/` | Ruby type signatures. |
| `igniter/spec/` | `igniter-workspace/igniter-ruby/spec/` | Ruby framework tests. |
| `igniter/bin/` | `igniter-workspace/igniter-ruby/bin/` | Ruby framework developer commands. |
| `igniter/packages/` | `igniter-workspace/igniter-ruby/packages/` | Ruby package umbrella. |
| `igniter/docs/guide/`, `igniter/docs/dev/`, `igniter/docs/store/` | `igniter-workspace/igniter-ruby/docs/` | Framework docs after pruning language canon references. |
| `igniter/examples/` | `igniter-workspace/igniter-ruby/examples/` | Ruby framework examples and demos. |

## Bring Selectively

| Source | Target | Rule |
| --- | --- | --- |
| `igniter/docs/research/` | `docs/research/` or archive | Bring only current framework research; move language-convergence material to archive/org. |
| `igniter/.agents/ruby-framework/` | `.agents/ruby-framework/` | Keep if operating docs still matter; compress if too historical. |
| `igniter/docs/assets/` | `docs/assets/` | Bring branding only if used by Ruby docs. |
| `igniter/packages/*/docs/` | package-local docs | Keep with package if current. |
| `igniter/packages/*/playground/`, `target/`, `tmp/`, `bench/` | package-local or exclude | Bring source playground only if useful; exclude generated build output. |

## Exclude From Living Repo

| Source | Disposition |
| --- | --- |
| `igniter/igniter-lang/` | belongs to `igniter-lang`, not Ruby framework. |
| `igniter/playgrounds/igniter-lab/` | belongs to `igniter-lab` or archive. |
| root `.idea/`, `.ruby-lsp/`, `.claude/`, `.DS_Store` | exclude. |
| `*.gem`, build outputs, package `target/`, package `tmp/` | exclude/archive by default. |
| old release/preflight reports that only justify past actions | archive unless current. |
| language governance tracks copied into Ruby docs | exclude or link outward. |

## First Detail Round

Proposed first per-repo card:

```text
Card: RUBY-SPLIT-P1
Track: igniter-ruby-positive-transfer-detail-v0
Goal: Turn this rough map into a Ruby framework copy plan, deciding package
boundaries, docs pruning, generated-output exclusions, and test commands.
```

## Physical Transfer Readiness

Not ready for physical copy yet.

Required before copy:
- rewrite root README/AGENTS to clarify Ruby Framework identity;
- decide package umbrella shape;
- exclude local IDE/build outputs;
- separate language references into cross-links;
- run Ruby specs after copy.
