# 0064 — The privileged merge poller reaches the overflow lane

- **Date:** 2026-08-07
- **Issue:** [#487](https://github.com/Verjson/.github/issues/487)
- **Category:** CI routing / runner topology
- **Status:** Accepted

## Context

ADR 0053 created `VERJSON_RUNNER_OVERFLOW` for "jobs that poll the pool they wait
on", and routed `preflight`, `gate` and `dispatch-merge` through it. It
**deliberately excluded** `ai-privileged-merge.yml`, whose `privileged_merge` job
its own measurement table names as the second-largest consumer of the lane — 29%
of lane runtime, and the most frequent job — dominated by polling at
`max_attempts` × `sleep 30`.

The escape hatch was therefore wired to the cheap dispatcher and withheld from the
~40-minute poller. `ai-privileged-merge.yml` says so about itself, two lines above
its own poll loop: "this job polls the SAME pool as the CI it waits for, so one
mis-provisioned runner starves the fleet (#363)."

Two ADRs deferred the fix rather than rejecting it:

- **ADR 0053** excluded it on a specific ground: `inputs.runner_labels` "which
  every consumer's generated caller passes", so an organization variable could not
  override it "without inverting the precedence between a caller input and
  organization configuration on the one workflow that carries merge authority."
  Moving it "means regenerating the callers, which should be a deliberate,
  separately reviewed change rather than a variable flip."
- **ADR 0056** listed it as a rejected alternative in exactly these words: "Worth
  doing and probably the right permanent fix, but it is a change to the privileged
  merge lane's runner topology and belongs with #341's re-scope, not here."

Both preconditions have since been met, which is what makes this decision
available now rather than a reversal of either ADR:

1. **ADR 0053's premise is already annotated as superseded in ADR 0053 itself.**
   ADR 0057 (#405) made `runner_labels` optional, and the generated caller now
   omits it. `Verjson/verjson-ai#195` is a live instance: that repository stopped
   passing the input, so its privileged merge routes by lane, which is precisely
   what made the missing overflow term observable from the adopter side (#180).
2. **#341's re-scope has landed** (`c60770c`), which is the work ADR 0056 said this
   belonged with.

## Decision

`vars.VERJSON_RUNNER_OVERFLOW` heads the **lane tail** of `privileged_merge`'s
`runs-on`, matching `ai-review-merge.yml:1910`:

```
inputs.runner_labels && fromJSON(inputs.runner_labels)
  || owner == 'Verjson' && fromJSON(vars.VERJSON_RUNNER_OVERFLOW
                                    || vars.VERJSON_LANE_PRIVILEGED
                                    || vars.VERJSON_LANE_FALLBACK
                                    || '["ubuntu-24.04"]')
  || 'ubuntu-24.04'
```

### Why no caller is regenerated, and no precedence inverts

This is the load-bearing detail, and it is why ADR 0053's stated objection does
not apply to this shape. `inputs.runner_labels` remains the **first** term of the
whole chain. Overflow sits inside the branch that is only evaluated when the input
is absent. So:

- A caller generated **before** #405, still passing `["self-hosted","general"]` —
  most of them until the #365 sweep — is bit-for-bit unaffected. Its input still
  wins over the organization variable.
- A caller generated **after** #405, passing nothing, reaches the overflow term.

No organization variable overrides any caller input. Nothing is regenerated. The
inversion ADR 0053 refused is not on the table, and the assertion that it stays
off the table is pinned by a test rather than by this paragraph.

### The test discovers polling jobs instead of listing them

#487 exists because ADR 0042 split `privileged_merge` into its own file and the
overflow term did not follow it across the split. A hardcoded list of
(workflow, job) pairs in the test would carry the identical blind spot: the next
split would not fail, because nobody updates a list they do not know exists.

`scripts/ci-gate/runner-routing-policy.test.sh` therefore sweeps every workflow
and derives the set, requiring **both** halves of ADR 0053's actual hazard:

- the job **parks** (a `sleep` with a numeric argument), and
- it parks **on checks it does not run** (`statusCheckRollup`, `check-runs`, or a
  commit status endpoint).

Both halves are required because the circularity is the deadlock — holding a pool
runner while waiting for other work that also needs a pool runner. `sleep` alone
over-matches, and there is a live false positive to prove it: `node-ci.yml`'s
`build-test` sleeps waiting for its own Docker Postgres to accept connections.
That wait needs no runner and starves nothing. A loose regex would have routed the
fleet's entire CI onto hosted overflow as a side effect of this change — a far
larger decision, reached by accident, on a job nobody was reviewing.

Today the sweep resolves to `privileged_merge`, `preflight` and `gate`.

## Consequences

- On an organization with `VERJSON_RUNNER_OVERFLOW` set, `privileged_merge` for
  lane-routed callers leaves the fixed pool. ADR 0053's measured 29% of lane
  runtime is the ceiling on what this frees; the realised figure will be lower
  until the #365 sweep regenerates the remaining callers, because until then most
  callers still pass the input and never reach the term.
- **The fleet watchdog is retained, and ADR 0056 is not reversed.** Its rationale
  narrows rather than disappearing: pre-#405 callers still route
  `privileged_merge` onto the pool by label, so a `privileged_merge` jam remains
  reachable and the watchdog remains its only mitigation. The comment block in
  `fleet-watchdog.yml` that asserted overflow "does NOT cover
  `ai-privileged-merge.yml`" is updated in the same commit — a stale narrative
  surface that contradicts the shipped routing is how this class of defect hides.
- Reverting is unchanged from ADR 0053 and remains a one-liner:
  `gh variable delete VERJSON_RUNNER_OVERFLOW --org Verjson`, effective for every
  run started afterwards.
- ADR 0053's exclusion paragraph is superseded by this ADR. ADR 0053 is not
  edited to say otherwise beyond a forward pointer, per this repository's rule
  that a decided ADR is superseded rather than rewritten.
