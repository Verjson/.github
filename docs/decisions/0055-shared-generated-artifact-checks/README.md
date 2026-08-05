# 0055 — Generated-artifact validation is a shared workflow with enumerated checks

- **Date:** 2026-08-05
- **Issue:** Verjson/.github#404
- **Category:** CI / reusable workflows
- **Status:** Accepted

## Context

Repositories that carry derived files — a generated ADR index, canonical
changelog fragments — each hand-wrote a local `generated-docs` job to check
them. The generator is genuinely repository-owned, but everything around it is
not: checkout, runner selection, permissions, timeout, and the wording of the
failure.

That copied plumbing is where the failures happened.
`Verjson/verjson-identity-lifecycle` pinned `runs-on: [self-hosted, GCP]`, a
label retired when the fleet moved off GCP. GitHub does not fail an unplaceable
job — it queues it. Job 92342330253 queued indefinitely and blocked every pull
request in that repository until consumer PR #7 replaced the job by hand. The
same defect class is what ADR 0041 and #401 addressed for this repository's own
workflows: a runner label written into ~90 consumer repositories cannot be
renamed without ~90 pull requests, so it is renamed in none of them.

A shared workflow moves that plumbing to one file where a lane flip fixes every
consumer at once. The open question was what a caller is allowed to ask for.

## Decision

Add `.github/workflows/generated-artifacts.yml`, `on: workflow_call`. It owns
checkout, lane-variable runner selection, `permissions: contents: read`, a
10-minute timeout, and one uniform failure report. Callers own their generators
and generated content.

**Supported checks are enumerated boolean inputs, and the workflow accepts no
shell.** `adr-index: true` runs `scripts/gen-adr-index.sh --check`;
`changelog: true` runs the pinned contract's `changelog.py`. A `command:` or
`script:` input would have been more flexible and is the reason to refuse it: a
reusable workflow that executes caller-supplied text turns every consumer's
workflow file — and anything that can open a pull request against one — into
arbitrary code execution on the shared self-hosted pool. Both selectors are
typed `boolean`, so a command-shaped value is rejected by GitHub before any
shell starts, and no input is interpolated into the script body at all: values
reach it through `env:`, where the shell treats them as data.

Adding a check is therefore a reviewed change to this repository, which is the
right cost — it is the same trade ADR 0041 made for runner labels, applied to
what a caller may execute.

**Enumeration bounds which path runs, not what code runs.** This is the limit of
the claim above and it must be stated, not left to be discovered: `adr-index:
true` executes `bash "$GITHUB_WORKSPACE/scripts/gen-adr-index.sh"` from the
consumer's pull-request checkout, which is caller-supplied code at a fixed path.
A shared workflow that checks a repository's generated files cannot avoid this —
running the repository's own generator is the check. What enumeration removes is
the *unbounded* form, where a caller names an arbitrary command; what remains is
one known path per enabled check, reviewable by reading this workflow.

The residual exposure is bounded by the runner selection above, not by the input
surface: `github.event.repository.private == true` routes trusted work to
`VERJSON_LANE_TRUSTED`, and everything else — every public repository, where a
fork pull request can propose the generator's contents — to
`VERJSON_LANE_UNTRUSTED`. The job also holds only `contents: read`, carries a
10-minute timeout, and both checkouts set `persist-credentials: false` so the
job token is not left in `.git/config` for repository-supplied code to read.

### The contract pin must be immutable

`contract_ref` becomes the `ref:` of a `Verjson/.github` checkout whose
`changelog.py` this job then executes, and `ref:` accepts any ref: a branch, a
tag, or `refs/pull/<n>/merge`. Because this repository is public, that last one
is reachable by anyone who can open a pull request, so an unconstrained
`contract_ref` would let an outsider choose the contract engine that runs on the
Verjson lane. A typo'd branch is the quieter version of the same defect: the
call succeeds and validates against a non-canonical contract.

A dedicated first step therefore rejects any `contract_ref` that is not exactly
40 lower-case hex characters, before either checkout runs, reusing the
`ref_is_immutable` rule from `scripts/node-workflow-pins.test.sh`. An
abbreviated SHA is rejected too: git resolves a prefix against whatever objects
exist at fetch time, so a prefix is not a pin (#312). `scripts/ci-gate/generated-artifacts.test.sh`
executes that step against a branch, a tag, `refs/pull/<n>/merge`, an
abbreviated SHA and an over-long value, and asserts the guard precedes the
contract checkout.

Three outcomes, distinctly reported:

- **clean** — the generator agrees with what is committed;
- **stale** — it does not, and the report names the exact command to re-run;
- **unavailable** — the caller opted into a check whose generator this
  repository does not have. That fails. It is a caller mistake, not a clean
  repository, and it is not reported as "stale" because that would send someone
  to regenerate a file with a script that is not there.

A call with every check disabled also fails. Booleans default to `false`, so a
mistyped input name would otherwise produce a workflow that validates nothing
and reports green — the fail-open shape this workflow exists to remove.

### Where the changelog check is folded, not duplicated

Where the generated artifact IS the changelog, `changelog: true` runs the
canonical engine from the `contract_ref` checkout — the same
`changelog.py validate` (and, on a pull request, `check-pr`) that
`changelog-validate.yml` runs under ADR 0038. It adds no second render pass:
`validate` already parses every unreleased fragment, which is the work a render
does.

**Amended 2026-08-05 (ADR 0059, #426):** the check now also renders
`render-next --as-released` into the job summary. That is not the second
verdict-bearing render this section refuses — the verdict is decided before it
runs, its exit status is never consulted for one, and a render failure warns
rather than fails. It exists because a released snapshot is immutable, so
without it the released form is first seen when it can no longer be changed.

Consequently `changelog: true` **replaces** the generated `changelog-validate`
caller rather than accompanying it. A repository calling both parses every
fragment twice for one verdict. A repository that needs only changelog
validation keeps its existing generated caller unchanged and adopts nothing
here.

The failure report names the command this job ran, at the path this job ran it
from — `python3 .changelog-contract/scripts/changelog.py …`. Under ADR 0038 the
engine exists only in `Verjson/.github`, so a remedy naming `scripts/changelog.py`
would be a path no consumer has. The report also names the failing subcommand
and the `contract_ref` to check out, so "one command regenerates it" stays true
off the runner.

Delegating by `uses:` would have been the stronger fold, but GitHub does not
allow an expression in a workflow-level `uses:`, so the ref could not be the
caller's `contract_ref`; a hard-coded self-reference would pin the contract in
the wrong file. `scripts/ci-gate/generated-artifacts.test.sh` instead asserts
that both workflows invoke the same engine and the same subcommands, and that no
`render-next` pass is added, so the two cannot silently diverge.

## Consequences

`scripts/ci-gate/runner-routing-policy.test.sh` binds the new job to the lane
policy: it appears in the enumerated route assertions, in the caller-override
list, and in the exhaustive sweep. A future edit that pins a literal label there
fails that suite rather than queueing a consumer's job forever.

The runner expression is the standard reusable-workflow chain — caller override,
then hosted for callers outside `Verjson`, then `VERJSON_LANE_TRUSTED` /
`VERJSON_LANE_UNTRUSTED` by visibility, degrading through
`VERJSON_LANE_FALLBACK` to the portable hosted tail of ADR 0040.

The cost is that a consumer needing an unsupported check cannot express it here
and must keep a local job until the check is added upstream. That is the
intended shape: the set of things this workflow will run stays reviewable by
reading one file.
