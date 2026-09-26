# 0118 — Route private terminal merge to hosted capacity

- **Date:** 2026-08-23
- **Issue:** [Verjson/.github#676](https://github.com/Verjson/.github/issues/676)
- **Extends:** [ADR 0117](../0117-route-private-terminal-merge-from-validated-lane-input/README.md)
- **Supersedes:** ADR 0089's admitted `self-hosted/general` selector for private terminal merge

## Context

The terminal merge job receives organization-level merge authority. ADR 0089 admitted
the exact `["self-hosted","general"]` JSON selector while private hosted-runner capacity
was unavailable. ADR 0117 made the caller-supplied `privileged_lane` effective only
after a credentialless admission job and an independent scheduling-time exact match.
The organization owner has now confirmed GitHub-hosted capacity, and issue #676 records
`["ubuntu-24.04"]` as the intended selector.

Persistent general runners execute ordinary organization workloads. Keeping terminal
merge authority on that fleet permits a prior compromise to affect a later privileged
job. The lane change must therefore update every admission comparison atomically, while
repository variables remain untrusted because they can shadow the organization value.

## Decision

The only admitted `privileged_lane` for a private Verjson terminal merge is the exact
JSON string `["ubuntu-24.04"]`.

The credentialless `validate_privileged_lane` job runs on fixed `ubuntu-24.04`, parses
the input with `jq`, and accepts only that one-element array. The secret-bearing
`privileged_merge` job remains ineligible unless GitHub's scheduling-time `if` also
compares the raw input to that exact string and the admission job succeeds. Its private
route then uses `fromJSON(inputs.privileged_lane)`. Neither job reads the organization
variable directly, consumes a runner-produced selector, or permits a fallback.

The other routes remain unchanged: the two enumerated public Verjson repositories use
fixed `ubuntu-24.04`; external organizations retain their optional `runner_labels`
override and hosted default; unknown Verjson identities or visibility fail closed.
Generated Verjson callers continue to pass `vars.VERJSON_LANE_PRIVILEGED`, so the
canonical generator interface and generated caller bytes do not change.

## Security analysis

A missing, malformed, widened, legacy self-hosted, or repository-shadowed input cannot
make the terminal job eligible. The raw-string comparison prevents JSON-equivalent but
non-canonical encodings from becoming additional admitted forms. The admission job has
empty permissions and receives no secret. Because both admission and terminal placement
for the private Verjson route are GitHub-hosted, Verjson's `ORG_ADMIN_TOKEN` cannot be
delivered to persistent self-hosted capacity through that route.

The organization variable is the rollout switch, but it is not itself an authorization
source inside the reusable workflow. Code must land before the variable is changed;
until then private callers fail closed rather than falling back to the former general
lane. Rollback requires restoring the previous workflow comparisons and variable as one
reviewed operation. Restoring only the variable leaves the terminal job safely
ineligible.

## Consequences

- Private and public Verjson terminal merge jobs use fresh GitHub-hosted
  `ubuntu-24.04` capacity after the organization variable is updated.
- External caller routing remains portable and byte-identical.
- A hosted-capacity or billing refusal leaves the terminal job queued or failed; there
  is no automatic fallback to persistent capacity.
- The live organization-variable mutation and representative canaries are separate
  rollout actions requiring live receipts after this code change lands.

## Correction (2026-09-26) — validate_privileged_lane's own check was not failing closed on an empty or whitespace-only input (#1612)

The Security analysis above claims a missing input "cannot make the terminal job
eligible." The credentialless `validate_privileged_lane` step's own check did not
independently hold that guarantee: it fed `PRIVILEGED_LANE` to `jq -e` through a bash
here-string (`<<<"${PRIVILEGED_LANE:-}"`), which always appends a trailing newline —
so an unset, empty, or whitespace-only input reached `jq` as a stream with no JSON
values, never a genuine parse error. `jq`/`jq -e` treats a zero-value stream as "the
filter never ran" and exits `0` regardless of `-e` (jq 1.6, reproduced locally),
unlike a real parse error or a `null`/`false` result. The step therefore printed
"privileged_lane validated: exact match" and returned success for exactly the input
shape this step exists to catch first — a caller that never supplied a lane at all.

**This did not enable a live privilege escalation.** The Decision above already
requires a second, independent check: `privileged_merge`'s own scheduling-time `if:`
separately compares `inputs.privileged_lane` to the literal string
`'["ubuntu-24.04"]'` at the GitHub Actions expression level, with no dependency on
`jq` or this step's diagnostic. For an empty or whitespace-only `privileged_lane`,
that literal-equality conjunct is false, so `privileged_merge` never became
schedulable regardless of `validate_privileged_lane`'s buggy success — the two-gate
design this ADR specifies contained the practical impact. The credentialless
admission step is still expected to fail closed on its own, independent of that
second gate, which is why this is a correction and not a "no action needed."

Fixed by requiring both `jq -e`'s exit status AND its stdout to be the literal string
`"true"` before treating the input as validated, rather than trusting either signal
alone: `-e`'s exit status is unreliable for a zero-value stream (the bug above), and
stdout alone is unreliable for the mirror case — a valid value followed by trailing
garbage (e.g. a second concatenated JSON value), where `jq` emits `"true"` for the
first value before failing on the unparsed remainder, so a bare stdout comparison
with stderr discarded would accept a string that is not actually an exact match.
Checking both closes both gaps. The Decision and the other malformed-input
guarantees in Security analysis above are unchanged; this restores the invariant
they already state rather than superseding it.
`scripts/ci-gate/privileged-lane-validation.test.sh` covers the missing-input and
whitespace-only cases alongside the malformed/widened/legacy/shadowed cases already
there.

References: [#1612](https://github.com/Verjson/.github/issues/1612).
