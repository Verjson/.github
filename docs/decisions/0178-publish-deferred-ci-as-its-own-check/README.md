# 0178 — Publish a deferred CI run as its own non-success check

- **Date:** 2026-09-14
- **Status:** Accepted
- **Supersedes:** nothing; extends [ADR 0156](../0156-deferred-ci-legible-to-merge-gate/README.md)

## Context

`node-ci.yml`'s `build-test` job carries `if: always()` so that a Renovate pull
request held on `renovate/stability-days` does not leave the required
`ci / build-test` context permanently unsatisfied (#191). When `eligibility`
resolves `should-run=false`, every one of `build-test`'s execution steps is
guarded by `needs.eligibility.outputs.should-run != 'false'` and is skipped; the
only step that runs is a `::notice title=CI deferred::` report. The job still
concludes `success`, so a required status check reports green having executed
nothing.

[ADR 0156](../0156-deferred-ci-legible-to-merge-gate/README.md) already
recognized this and chose to keep the context satisfying while making the
deferral *legible* — a titled annotation on the check run, plus a canonical
`scripts/assert-no-deferred-checks.sh` that reads the Checks API annotations
endpoint and fails closed. That closed the gap only for callers who adopt the
script.

**`Verjson/verjson-cli#251` is the evidence that the opt-in half is not enough.**
While `renovate/stability-days` was pending, `ci / eligibility` deferred the
credentialless lane, `ci / build-test` reported "deferred CI" and skipped all 26
of its real steps, and the check still reported green to the branch-protection
gate. That repository's `STALE_CLI_PROJECTS_LOCK` guard — a repository-local
contract check, not part of org CI — therefore never ran, and a lockfile that
violated a deliberate version hold passed a green required check. The violation
stayed invisible until Renovate later rebased. The annotation existed and nobody
read it, because the surface everyone actually reads is `statusCheckRollup`.

The behavior is canonical: it lives in this repository's `node-ci.yml` and in the
generated `node-ci-protected.yml`, so it reaches every adopter — 31 or more
repositories.

## Decision

**Keep the required context satisfying; publish the deferral as a separate,
non-success check.** Concretely, in `node-ci.yml` (and therefore in the generated
`node-ci-protected.yml`):

- `build-test` is unchanged. It still runs `if: always()`, still reports, and
  still concludes `success` on a defer, so `ci / build-test` remains satisfied
  and no held Renovate pull request wedges.
- A new `deferred-ci` job runs **only** when
  `needs.eligibility.outputs.should-run == 'false'`, emits an `::error
  title=CI deferred::` naming exactly what was not verified, and exits 1.

The rejected alternative was to make the deferred context itself non-satisfying
(report `failure`, or not report `build-test` at all). That is the option the
evidence most directly argues for — a hold that does not hold is worse than no
hold — and it was still rejected, for a reason specific to this mechanism rather
than to cost.

### Why the deferred context stays satisfying

Nothing re-fires a deferred run on the same head. `eligibility` defers on a
*pending* `renovate/stability-days` status attached to the head SHA. When the
release-age window elapses, Renovate resolves that status; it does not by itself
re-dispatch this workflow. CI executes for real only once Renovate rebases onto a
new head and a fresh `pull_request` event fires. Making `ci / build-test`
non-satisfying therefore does not produce "blocked until the window clears" — it
produces "blocked until Renovate happens to rebase", with no bound and no
recovery path a reviewer can trigger short of a manual re-run. That is #191's
wedge, and re-introducing it fleet-wide as a side effect of a visibility fix
would be exactly the silent, infrastructure-unsupported validation this
organization's conformance rule forbids.

`neutral` was also rejected: the canonical pre-merge assertion accepts `NEUTRAL`
and `SKIPPED`, so a neutral conclusion changes nothing for the gate that matters.
ADR 0156 reached the same conclusion.

A separate job has neither problem. Branch protection only evaluates the contexts
a ruleset names, and `config/required-check-bindings` names `ci / build-test` and
`ci / eligibility` explicitly — `deferred-ci` is not among them and must not be
added, for the same reason. So the new check cannot wedge a merge that branch
protection would otherwise allow, while it *is* present in the head's
`statusCheckRollup` with a `FAILURE` conclusion, which is the one projection
every gate, agent, and human already makes.

## Consequences

**Fleet-wide, and deliberate.** In every adopter of `node-ci.yml` and
`node-ci-protected.yml`:

- A Renovate pull request whose CI is deferred now carries a red
  `<caller-job> / deferred-ci` check and a failed workflow run for the duration
  of its release-age hold. The pull request looks failing in the GitHub UI. This
  is the intended signal, not noise: nothing on that head has been verified.
- Any caller asserting a fully green rollup —
  `[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or
  . == "SKIPPED")`, the form this organization's agents and `--admin` merge
  procedure use — now returns `false` for a deferred head and **will not merge
  it**. Before this change it returned `true`. This is the `verjson-cli#251` fix.
- Renovate's own non-platform automerge, which requires the branch status to be
  green, likewise will not automerge a deferred head. GitHub's native auto-merge
  and branch protection are unaffected, because both evaluate only required
  contexts.
- `ai-privileged-merge.yml`'s `REQUIRED_CHECK_POLICY` validation asserts the
  workflow run backing a required check concluded `success`. A deferred run's
  workflow conclusion is now `failure`, so that gate rejects the promotion. The
  rejection is correct and fail-closed, but its message
  (`required check ... is not backed by the trusted exact-head workflow run`)
  does not name the deferral. Giving that path a deferral-specific message is a
  follow-up; it is not required for this decision, and it is not a regression,
  since the alternative today is promoting an unexercised head.
- One extra short runner job per deferred run. Negligible, and only on the defer
  path.

**Recovery is unchanged.** When the release-age gate clears and Renovate rebases,
the new head runs CI for real, `deferred-ci` does not run at all, and the rollup
is green on its own merits. A reviewer who wants CI now can `workflow_dispatch`,
which `eligibility` never defers.

**What this does not fix.** Consumers of the `ci-eligibility` composite action
build their own jobs and are responsible for their own reporting; this decision
reaches only the two reusable workflows. `scripts/assert-no-deferred-checks.sh`
and ADR 0156's annotation remain valid and are not retracted — they now cover the
composite-action path that the separate check does not reach.

## Verification

`scripts/ci-gate/deferred-ci-visibility.test.py` pins both halves against both
workflows: that `build-test` still reports `if: always()`, that a deferred
`build-test` executes nothing but its own notice, that a `deferred-ci` job exists
gated on the defer condition alone, and that its run block actually exits
non-zero and cannot be neutralized with `continue-on-error`. It is registered in
`scripts/actions-ci-groups.tsv` under `platform`.
