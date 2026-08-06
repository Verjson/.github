# 0062 — The release caller is generated, and it verifies before it tags

- **Date:** 2026-08-06
- **Issues:** [#463](https://github.com/Verjson/.github/issues/463), [#464](https://github.com/Verjson/.github/issues/464), [#465](https://github.com/Verjson/.github/issues/465)
- **Extends:** ADR 0038 (canonical changelog contract), ADR 0060 (a release is dispatched, never derived), ADR 0052 (`push_token` is not `GITHUB_TOKEN`), ADR 0059 (released snapshots are immutable)
- **Category:** release authority — **sensitive class**

## Context

`scripts/gen-changelog-caller.sh` generated three of an adopter's four contract files —
the validate caller, the renderer, and the contract test — and not the fourth. So every
repository that publishes something hand-copied `.github/workflows/release.yml` from
`Verjson/verjson-payments`, and every defect in that one shape reached all twenty-one
migrated repositories by inheritance. Three repository PMs hit three different defects in
it independently, within days of each other, and each filed a handoff rather than a fix:
#463 (verjson-video-forge), #464 (verjson-email), #465 (verjson-graphql-conventions).

The generator's own header already argued this case for the other three outputs —
"hand-writing this three times already produced three shapes". The release caller was the
counter-example nobody had closed.

The three defects:

1. **Verification ran after the irreversible act.** `snapshot` called
   `changelog-release.yml`, which consumes `NEXT/`, writes `CHANGELOG/<version>.md`,
   commits, tags and pushes to the default branch in one atomic push. `publish` was
   `needs: snapshot`, and only then ran `npm ci`, build, lint, typecheck, test and
   publish. `--atomic` protects the push, not the release: once it lands the version is
   spent, and **neither dispatch recovers it** — the same version is refused because the
   tag exists, a higher version is refused with `release selected no fragments` because
   `NEXT/` was already consumed. Recovery is manual surgery on a ruleset-protected
   branch.
2. **`npm ci` installed with `GITHUB_TOKEN`.** A repository-scoped token cannot read a
   private GitHub Packages package owned by a *different* repository, so any adopter with
   a private `@verjson/*` devDependency 401s. Canonical `node-ci.yml` documents exactly
   this and does the opposite; the copied release caller did not.
3. **The two halves landed on different runner pools.** A caller that omitted the
   optional `runner:` input let `changelog-release.yml` route the snapshot through
   `VERJSON_RUNNER_OVERFLOW` (hosted for a private Verjson repository) while the copied
   `publish` job hardcoded an expression resolving to `VERJSON_RUNNER_DEFAULT`
   (self-hosted). On a private repository without hosted minutes, the half that mutates
   protected `main` queues silently — no check run, no error, no signal.

All three fire only on a real dispatch, and most adopters had not dispatched yet.

## Decision

**`gen-changelog-caller.sh` gains a fourth output, `release-node`, and the release caller
stops being hand-copied.** The generated shape closes all three defects by construction:

- A `verify` job checks out `github.sha` and carries every check that can say "no" before
  anything is tagged: dispatched-from-the-default-branch, exact `v`-prefixed SemVer
  format, tag and snapshot absence, and the repository's full suite. `snapshot` declares
  it in `needs:`.
- `snapshot` passes an explicit `runner:`, and the same expression routes `verify` and
  `publish`, so one release cannot span two pools.
- `publish` installs with `secrets.NODE_AUTH_TOKEN` and publishes with
  `secrets.GITHUB_TOKEN`. `GITHUB_TOKEN` is correct for publishing the repository's own
  package and wrong for reading someone else's.
- The workflow is `workflow_dispatch` only, and the reusable call is pinned at the same
  immutable contract commit as the other three outputs.

**Verifying the default branch head is a sound proxy for the not-yet-existing tag.** The
snapshot commit writes `CHANGELOG/<version>.md`, generates `CHANGELOG.md`, and removes
`NEXT/` fragments — it touches no source, no config and no dependency. That claim is not
asserted, it is exercised: a disposable clean checkout run of the pinned
`scripts/changelog.py release` produced a release commit whose diff was exactly
`CHANGELOG.md`, `CHANGELOG/<version>.md` and the consumed `NEXT/` fragments, with the
seeded source file untouched. The reasoning is written into the generated file's own
comments so the next reader does not have to re-derive it.

**The adopter-facing contract test enforces it.** The emitted
`scripts/changelog-contract.test.sh` now rejects a release caller that carries no
generator provenance at the pin, that runs the snapshot with no `needs:`, that passes no
explicit `runner:`, that installs with `GITHUB_TOKEN`, or that is reachable by a trigger
which would have to infer a version. Adopters wire that suite into `npm test`, so the
defect surfaces on the next pull request rather than on the first dispatch.

### Judgement call: `release-node`, not `release`

The mode names its stack. `gen-changelog-caller.sh` serves ~90 repositories, but a
release caller exists only where there is something to publish, and today every such
repository is a Node package — `node-release.yml`, the retired predecessor, was Node-only
too (ADR 0060). A single `release` mode would have to guess, and a stack axis added
before a second stack exists is speculative. Naming the stack keeps a future
`release-python` or `release-container` an additive mode rather than a reinterpretation
of an existing one, and it makes a bare `release` fail loudly instead of silently
emitting Node. Adopters with nothing to publish keep having no release caller at all,
which remains a supported shape the emitted contract test tolerates.

### Judgement call: the suite is configured by a hook, not by editing the file

An adopter whose suite is not `npm test` commits an executable
`scripts/release-verify.sh`; `verify` runs it instead of the default Node sequence. The
escape hatch is a separate, adopter-owned file on purpose. A generated artifact adopters
must edit is the defect being removed here, not a compromise available to it — the same
reasoning that forbids hand-editing the emitted contract test. The alternative, a
repository variable, would move release-gating configuration out of the repository into
an invisible org surface, where no pull request can review it.

## Consequences

- Twenty-one migrated repositories carry the old shape and must regenerate. Their next
  contract-test run fails with the exact command that fixes it. That break is deliberate:
  a latent unrecoverable failure that reports green is worse than a red test.
- `release-node` exists only from this commit forward, so `docs/changelog/migration.md`'s
  `PIN` must move to a commit at or after it before an adopter can generate a release
  caller from the documented pin. `scripts/contract-pin.test.sh` enumerates the three
  older modes; `release-node` joins that loop when the pin moves.
- `verify` costs a full extra suite run per release. That is the price of the property
  bought: a red tree now fails in the cheapest possible place instead of spending a
  version number. Demonstrated end to end — a failing `verify` left no tag, no
  `CHANGELOG/`, and `NEXT/` untouched, and the *same* version released cleanly once the
  suite was fixed.
- This does not interact with #437. That issue is about the *validate* caller's workflow
  name (`changelog-validate.yml` vs `generated-artifacts.yml`) and the contract test's
  grep for it; `release-node` adds a separate file with its own assertions and changes
  neither the emitted `changelog.yml` nor the string #437 is about. The adopter
  instruction for #437 is unchanged: stay on `changelog-validate.yml`.
