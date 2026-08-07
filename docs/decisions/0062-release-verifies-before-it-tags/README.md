# 0062 — The release caller is generated, and it verifies before it tags

- **Date:** 2026-08-06
- **Issues:** [#463](https://github.com/Verjson/.github/issues/463), [#464](https://github.com/Verjson/.github/issues/464), [#465](https://github.com/Verjson/.github/issues/465), [#519](https://github.com/Verjson/.github/issues/519), [#520](https://github.com/Verjson/.github/issues/520), [#535](https://github.com/Verjson/.github/issues/535)
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
- **`changelog-release.yml` now checks out that same `github.sha`** instead of
  re-resolving the default branch name at snapshot time.
- `snapshot` passes an explicit `runner:`, and the same expression routes `verify` and
  `publish`, so one release cannot span two pools.
- `publish` installs with `secrets.NODE_AUTH_TOKEN` and publishes with
  `secrets.GITHUB_TOKEN`. `GITHUB_TOKEN` is correct for publishing the repository's own
  package and wrong for reading someone else's.
- The workflow is `workflow_dispatch` only, and the reusable call is pinned at the same
  immutable contract commit as the other three outputs.

**Both halves of a release pin the same commit, or verification proves nothing.** A
`verify` job that runs before the snapshot only helps if the snapshot takes the tree
`verify` read. `changelog-release.yml` previously checked out
`github.event.repository.default_branch` — the branch *name*, re-resolved at snapshot
time — so anything merged between the two reads was tagged, pushed and published without
any job having checked it. The window is not theoretical: `verify` holds it open for its
whole suite run, and `concurrency` with `cancel-in-progress: false` holds it open again
behind a queued release. Adding `verify` to the caller while leaving the reusable
workflow re-resolving the name would have shipped the appearance of the property without
the property, so both now check out `github.sha`, the commit the dispatch names.

**The consequence of pinning is that a raced release fails closed.** `changelog.py
release` ends in one `git push --atomic` of the release commit and its tag. Taken from
the dispatch commit, that push is non-fast-forward as soon as the default branch has
moved, so the release aborts with **no tag, no `CHANGELOG/<version>.md` on the branch,
and every `NEXT/` fragment still unconsumed** — the version is not spent and a
re-dispatch from the new head succeeds. Exercised, not asserted: against a remote whose
`main` advanced mid-release, the old branch-name shape pushed and tagged a tree
containing content nothing had verified; the pinned shape was rejected and left the
remote untouched, and the same release then ran cleanly on an unraced remote, tagging the
release commit on a detached HEAD.

**What `verify` still cannot check is the snapshot commit itself**, which does not exist
when the suite runs. Verifying the dispatch commit stands in for it because of what the
snapshot commit contains: it writes `CHANGELOG/<version>.md`, generates `CHANGELOG.md`,
and removes `NEXT/` fragments — no source, no config, no dependency. That claim is
exercised too: a disposable clean-checkout run of the pinned `scripts/changelog.py
release` produced a release commit whose diff was exactly `CHANGELOG.md`,
`CHANGELOG/<version>.md` and the consumed fragments, with the seeded source file
untouched. All of this reasoning is written into the generated file's own comments and
into `changelog-release.yml` at the checkout, so the next reader does not re-derive it —
or, worse, "simplify" the pin back to a branch name.

**The adopter-facing contract test enforces it.** The emitted
`scripts/changelog-contract.test.sh` now rejects a release caller that carries no
generator provenance at the pin, that runs the snapshot with no `needs:`, that passes no
explicit `runner:`, that installs with `GITHUB_TOKEN`, or that is reachable by a trigger
which would have to infer a version. Adopters wire that suite into `npm test`, so the
defect surfaces on the next pull request rather than on the first dispatch.

**2026-08-07 — the dispatched package version is part of the verified build
input (#519).** A Node build may read `package.json`, so stamping the dispatched
version only beside `npm publish` lets verification and the publish build embed
different versions. The generated caller now applies the same uncommitted
`npm version --no-git-tag-version --ignore-scripts` stamp before the verification suite and
before the publish build. The snapshot remains changelog-only; the stamp is
repeated from the explicit dispatch input after the release tag is checked out.
The generated adopter contract test rejects either job when its build can run
before that stamp. Lifecycle scripts are disabled so stamping is a metadata-only
operation rather than an additional unverified package-code execution surface.

**2026-08-07 — publication reruns reconcile immutable registry state (#535).**
The publish job packs the built snapshot once and records its package identity,
version, and sha512 integrity. If `npm publish` fails, the job continues only
after authenticated registry access proves that the exact name, version, and
integrity already exist; missing, spoofed, inaccessible, or divergent state
fails closed. The package and tag are never overwritten. GitHub Release notes
are then created or reconciled from the immutable changelog snapshot, so a
transient failure after npm accepted the package no longer makes the release
permanently incomplete.

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

### 2026-08-07 refinement: adopter release parameters are generator inputs

The generated Node caller defaults to `@verjson` and Node 24, but those values
are not release-authority invariants. Scaffolders may select another lowercase
npm scope and numeric Node version through validated `--scope` and
`--node-version` generator options. The same options configure the generated
contract test, which requires both release jobs to use them. This preserves the
decision that generated artifacts are never hand-edited while keeping existing
two-argument invocations compatible in their selected defaults (#520).

## Consequences

- Twenty-one migrated repositories carry the old shape and must regenerate. Their next
  contract-test run fails with the exact command that fixes it. That break is deliberate:
  a latent unrecoverable failure that reports green is worse than a red test.
- `release-node` exists only from this commit forward, so `docs/changelog/migration.md`'s
  `PIN` must move to a commit at or after it before an adopter can generate a release
  caller from the documented pin. `scripts/contract-pin.test.sh` enumerates the three
  older modes; `release-node` joins that loop when the pin moves.
- The `github.sha` pin lands in `changelog-release.yml`, which every adopter of the
  contract calls — including those with no release caller and no `verify` job. For them
  the change is narrower but the same direction: a release dispatched at commit A now
  tags commit A rather than whatever `main` happened to be by the time the runner
  checked out. The visible new failure mode is a release that aborts on a
  non-fast-forward push because `main` moved mid-run. That is the intended trade: a
  loud, re-dispatchable failure instead of a silent tag over unverified content.
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
