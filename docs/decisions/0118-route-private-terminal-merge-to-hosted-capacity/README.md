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
