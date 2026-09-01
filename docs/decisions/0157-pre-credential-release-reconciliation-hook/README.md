# 0157 — Container releases reconcile derived inputs before minting the release credential

- **Date:** 2026-09-01
- **Issue:** [#1203](https://github.com/Verjson/.github/issues/1203)
- **Blocks:** [Verjson/verjson-github-runner#195](https://github.com/Verjson/verjson-github-runner/issues/195)
- **Category:** release authority, production credentials, and pre-credential code execution — **sensitive class**
- **Status:** Accepted
- **Extends:** [ADR 0078](../0078-container-release-and-runner-deployment-contract/README.md)

## Context

The canonical reusable `container-release.yml` copies the provenance-verified immutable
release manifest into `RELEASES/containers/` and commits only that manifest, the generated
changelog snapshot, and the tag. A repository whose *derived* build inputs must be
reconciled to the just-published immutable base digest has nowhere to do it inside that
atomic release commit.

`Verjson/verjson-github-runner#195` is the concrete failure: v0.2.1 was released while every
derived Dockerfile default remained pinned to v0.2.0, leaving `main` red immediately after a
green release. The obvious remedies are both wrong. Reconciling in a follow-up commit means
the tag names a tree that never built. Letting a generated consumer hand-edit the pinned
workflow destroys the byte-identity contract that makes the release path reviewable at all.

So the hook has to exist, and it has to run *inside* the release job. That is precisely what
makes it dangerous: the only useful position for it is after the manifest is proven and
before the release commit, which is also one step before the job mints a GitHub App token
carrying `contents: write` on the release repository — a credential that can push to
`main` past branch protection.

### Threat model

An under-constrained hook in that position could:

1. **Exfiltrate or misuse the release credential** — by reading it out of the ambient
   environment, or by leaving a background process alive to observe the token minted in the
   following step.
2. **Corrupt the release commit** — by writing files the reviewers of the release never saw,
   which the subsequent `git commit` would then tag and publish under a verified manifest.
3. **Escalate into the pinned engine** — the release step executes
   `.container-release-contract/scripts/changelog.py` *with* the App token. That checkout is
   on disk, untracked from the consumer repository's point of view, when the hook runs.
4. **Bypass the file allowlist** — through symlinks, deletion-and-recreate, file-mode or
   type changes, untracked output, or index manipulation, all of which a naive
   `git diff --name-only` check accepts.
5. **Be widened at release time** — if the allowlist or command were a `workflow_dispatch`
   input, anyone who can dispatch a release could choose what code runs pre-credential.

## Decision

Add one **opt-in, generator-declared, fail-closed** reconciliation step to the reusable
workflow, enforced entirely by immutable contract code.

**Generation time, not run time.** `scripts/gen-container-release.sh` gains
`--reconcile-allow <path>` (repeatable, `workflow` and `contract-test` kinds only). It bakes
a literal `reconcile-allowlist: '["…"]'` into the generated caller's `with:` block. The
caller's `workflow_dispatch` inputs remain exactly `version` and `candidate-manifest`, and
the generated caller is byte-pinned by the generated contract test — so the allowlist is
reviewed in a PR and cannot be widened by a dispatcher. This mirrors how `--build-runner`
and `--release-asset` are threaded through `gen-changelog-caller.sh`.

**Exact allowlisted command.** The hook is always `scripts/release-reconcile.sh` in the
consumer repository — a constant of the contract, not a configurable path. It must be
tracked, a regular file (not a symlink), and executable. There is no shell fragment,
command string, or interpreter selection anywhere in the input surface.

**Position.** The step runs after `Fail-closed preflight and immutable plan` (so
`release-manifest.json` exists and is provenance-verified), after the pinned engine
checkout, and before `Require the release App client ID` / `Mint exact-repository release
App token`. `scripts/container-release-reconcile-hook.test.py` asserts all four orderings
against the real workflow and rejects mutants that move the step.

**Enforcement lives in the contract, not the consumer.** The validator is
`scripts/container_release_reconcile.py`, executed from `.container-release-contract/` at
the pinned contract SHA. It is deliberately *not* a generated consumer-side artifact: a
consumer-side copy of the thing that constrains the consumer is not a constraint. The
existing pinned checkout is widened by exactly one file to carry it.

**Bounded inputs.** The step's `env:` is exactly `VERSION`, `CONTRACT_REF` and
`RECONCILE_ALLOWLIST`. The validator then builds the hook's environment *from scratch* —
`PATH`, `HOME`, `LANG`, `RELEASE_VERSION`, `RELEASE_MANIFEST` — rather than filtering a copy
of the runner environment. An allowlist is used instead of the denylist pattern used by
`release-build.sh` because a denylist cannot keep up with newly introduced credential
variables, and the blast radius here is the release App token.

**Fail-closed validation.** Before the hook: the allowlist is structurally validated
(normalized repository-relative paths, no `..`/`.`/`.git*` segments, no `RELEASES/`,
`CHANGELOG/`, `NEXT/` or release-engine script, unique, ≤ 32 entries, each already a tracked
regular file); the manifest path is bounded; the pinned checkout is confirmed to be at the
contract ref and unmodified; the tracked tree is confirmed clean. After the hook: every
`git status --porcelain=v1 -z -uall` record must be either untracked output that already
existed before the hook, or an unstaged content modification (` M`) of an allowlisted path.
Deletions, renames, type changes, index staging, and any new untracked path are rejected.
`git diff --raw` then requires the source and destination modes to be equal and to be a
regular blob, which rejects mode flips and symlink substitution, and the filesystem is
re-checked for symlinks. On any rejection — non-zero exit, signal, timeout, or failed
validation — the index is reset, tracked files are restored, hook-created untracked files
are removed, and the job exits non-zero without ever reaching the mint step.

**Idempotence is enforced, not assumed.** Releases are retried. The hook is run a second
time against its own output and the reconciled blob hashes must be unchanged. (Blob hashes,
not `git diff --raw`: for unstaged worktree changes git reports an all-zero destination
hash, so `--raw` cannot distinguish two different reconciliations of the same path — a
defect found by the idempotence test itself.)

**Containment after the hook.** The hook runs in its own process group with `stdin` closed
and a 300-second timeout; the group is `SIGKILL`ed on completion, so nothing it backgrounds
can observe the token minted in the next step. The validator re-verifies the pinned checkout
afterwards, and the release step re-binds it (`rev-parse HEAD` equals `contract-ref`,
`scripts/changelog.py` unmodified) immediately before executing it with the token.

**Exactly one commit.** The validator stages only the validated paths. The release step then
asserts that the staged set is exactly the release manifest plus the reconciled paths it
recorded, so reconciled files ride in the same commit and tag as the manifest and changelog,
and nothing else can.

**Opt-in.** With no `--reconcile-allow`, the generated caller is byte-identical to today and
the step is skipped by `if: ${{ inputs.reconcile-allowlist != '' }}`. The generated contract
test additionally asserts the negative — no `reconcile-allowlist` in the caller and no
undeclared `scripts/release-reconcile.sh` — so a hook cannot appear without review.

## Consequences

- Consumers such as `verjson-github-runner` can pin derived build inputs to the released
  digest inside the release commit, closing the class of failure in #195.
- The reusable workflow now executes consumer-authored code before credential minting. It
  already ran consumer-side `container_release_*.py` at that point, so this is a widening of
  an existing surface rather than a new one — but it is a deliberate widening, constrained
  by an org-owned enforcer and covered by adversarial tests
  (`scripts/container_release_reconcile.test.py`) that attempt each bypass in the threat
  model above and require rejection.
- Reconciliation doubles the hook's execution time by design (the idempotence fixed-point
  check). Hooks are expected to be small deterministic rewrites; a hook that cannot tolerate
  running twice is not safe to run in a retryable release.
- The pinned engine checkout is widened from one file to two. It remains sparse,
  cone-mode-off, and credential-free, and `container_release_changelog_engine.test.py` still
  asserts it exactly.
- Adopters must regenerate the whole artifact set at one contract SHA to pick this up; the
  contract test's negative assertions are new bytes even for unconfigured adopters.
- **Residual risk, stated plainly:** a malicious hook can still consume runner CPU and read
  the repository tree, and validation is `git`-state-based, so it does not model a hook that
  attacks the runner itself. The mitigation is that the hook, its allowlist, and the pinned
  contract SHA are all reviewed in the consumer's own PR before any release can use them.
