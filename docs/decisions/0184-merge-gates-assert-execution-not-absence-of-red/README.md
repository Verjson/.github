# 0184 — A merge gate asserts that verification executed, not that nothing is red

- **Date:** 2026-09-17
- **Status:** Accepted
- **Extends:** [ADR 0156](../0156-deferred-ci-legible-to-merge-gate/README.md), [ADR 0178](../0178-publish-deferred-ci-as-its-own-check/README.md)
- **Related:** [ADR 0024](../0024-absent-checks-fail-closed/README.md)

## Context

The pre-merge assertion this organization's agents and `--admin` merge procedure
use is a single boolean:

```
gh pr view N --json statusCheckRollup --jq \
  '[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'
```

[ADR 0178](../0178-publish-deferred-ci-as-its-own-check/README.md) deliberately
introduced a non-`SUCCESS` `deferred-ci` check, and recorded the consequence
that this predicate "now returns `false` for a deferred head and **will not
merge it**. This is the `verjson-cli#251` fix." That is correct, and this
decision does not retract it.

What ADR 0178 did not address is what the predicate *says* when it returns
`false`. It says nothing. One bare `false` is the sole output for at least four
materially different head states:

| Head state | Correct response |
| --- | --- |
| A required check genuinely failed | Fix the code |
| The head was deferred and nothing ran (ADR 0178) | Wait for the rebase, or `workflow_dispatch` |
| A required check never reported at all | Fail closed (ADR 0024) and investigate |
| A non-required advisory check is red | Judgement call, usually not a merge blocker |

A predicate that cannot distinguish "this head was never verified" from "this
advisory check is red" is not merely unhelpful. It is actively unsafe, because
the cheapest way to make an opaque `false` go away is to widen the accepted-
conclusion list — and the first conclusion anyone widens it to accept is
`FAILURE` on the `deferred-ci` entry that is making an otherwise-green Renovate
pull request look broken. That single edit restores exactly the
`Verjson/verjson-cli#251` condition ADR 0178 was written to end: a head merged
having executed no test, lint, type check, or repository-local contract guard.

The predicate has a second defect independent of deferral. It reads the required
set off the head — that is, off whatever the head happened to report. A head
that reports *nothing* satisfies `all(...)` over an empty list. The rollup
length guard in `scripts/assert-no-deferred-checks.sh` catches the fully-empty
case, but not a head that reported two advisory checks and none of its required
ones. Inferring the required set from the artifact being judged is the same
class of error as parsing an adopter-controlled workflow header and trusting it.

## Decision

**Replace the single boolean with three separately-named gates, each of which
fails closed with its own exit code and its own message.** The implementation is
`scripts/assert-mergeable-head.sh`.

- **Gate A — required-context completeness.** The required set is read from the
  ruleset governing the pull request's *base ref*
  (`repos/{repo}/rules/branches/{ref}`), never inferred from the head. Every
  required context must be present on the head, `COMPLETED`, and concluded
  `SUCCESS`, `NEUTRAL`, or `SKIPPED`. An absent required context fails closed
  per [ADR 0024](../0024-absent-checks-fail-closed/README.md); it is not
  satisfied by its own absence. A base ref that declares no required checks at
  all fails closed too, because a green rollup proves nothing about an
  ungoverned ref.
- **Gate B — positive evidence of execution.** A rollup entry proves a check
  *reported*; it does not prove a check *worked*. ADR 0178's `deferred-ci` job
  runs only on a defer, so its having run at all — any conclusion other than
  `SKIPPED`, explicitly including a conclusion this gate would otherwise treat
  as passing — is direct evidence the head was never exercised. ADR 0156's
  deferral annotation is also checked, because consumers of the `ci-eligibility`
  composite action build their own jobs and never emit a `deferred-ci` check.
  The message names the deferral in those words and says what to do instead.
- **Gate C — no unexplained red.** Anything else pending or non-passing blocks,
  listed by name.

Every failure is a `::error::` and a distinct exit code (`3`, `4`, `5`; `1` for
an assertion that could not be evaluated, `2` for usage). The script never
prints a bare `false` and never exits `0` on an unanswered question.

### Why three gates rather than a better single predicate

The safety property being bought is not accuracy — the existing predicate is
already accurate in the sense of returning `false` on a deferred head. It is
**that relaxing the gate requires naming which gate you are relaxing.** Widening
`all(. == "SUCCESS" or ...)` is a one-token edit with no local evidence of what
it costs. Deleting Gate B is an edit to a block whose own error text explains
that the head was never verified and cites the incident. The three-way split
exists to make the unsafe change expensive to write and obvious to review; it is
a control on the human under time pressure, not on the API.

### Why the base ref's ruleset, and why that call failing is fatal

An unreadable ruleset means the required set is unknown. The available
alternatives are to fall back to the head's own reported checks — reintroducing
the inference this decision removes — or to refuse. It refuses. A transient API
failure blocking a merge for one retry cycle is the correct trade against a
merge gated on a set the head itself chose.

## Consequences

- `scripts/assert-no-deferred-checks.sh` (ADR 0156) is **not** retracted or
  modified. It remains correct for its narrower question, and callers that use
  it keep working unchanged. This decision adds a stronger assertion beside it
  rather than altering a script other repositories already invoke; nothing is
  silently made stricter under an existing name.
- The new script requires `repos/{repo}/rules/branches/{ref}` read access, which
  a token with `contents: read` on the repository already has. On a repository
  with no ruleset on its default branch it will refuse to pass, by design. That
  is a real behavioral difference from the old predicate and the reason it ships
  as a new entry point rather than as an in-place upgrade.
- Adoption is deliberately not forced in this decision. Migrating the
  organization's merge procedure and agent guidance from the one-line predicate
  to this script is a follow-up, tracked separately, because it touches every
  repository's merge path and is properly sequenced with the organization
  contract-distribution decision rather than ahead of it.

## Verification

`scripts/assert-mergeable-head.test.sh` exercises the script against a stubbed
`gh`, asserting the specific gate and exit code for each state: an absent,
pending, and failing required context; a base ref with no required checks; a
legacy commit-status context; a `deferred-ci` that ran with `FAILURE` and with
`SUCCESS`; a `deferred-ci` that was `SKIPPED` on the normal path; an ADR 0156
annotation; a failing advisory check; and every API failure and unresolvable
field failing closed rather than green. It is registered in
`scripts/actions-ci-groups.tsv` under `merge-gate`.
