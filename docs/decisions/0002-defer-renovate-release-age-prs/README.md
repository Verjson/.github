# 0002 — Defer AI review of Renovate PRs whose release-age gate is still pending

- **Date:** 2026-07-15
- **Status:** Accepted
- **Amends:** [0001 — Renovate auto-merge + org-wide advisory AI review](../0001-renovate-automerge-ai-review/README.md)

## Context

The org merge gate (`.github/workflows/ai-review-merge.yml`) classifies each PR
into a lane; the `ai` lane runs a model review, but only after waiting for the
rest of CI to go green (up to 45 min, on a scarce self-hosted `gate` runner).

The shared Renovate policy (`Verjson/renovate-config`) sets
`minimumReleaseAge: "3 days"` with `internalChecksFilter: "strict"`. For a
normal version bump, `strict` filters the not-yet-aged version out during
package lookup, so **no branch is raised** — the desired outcome, no CI spend.

`internalChecksFilter` only filters version *candidates*, though. A Renovate
**replacement** PR (e.g. `framer-motion` → `motion`, `Verjson/toquorum#72`) is
raised by the replacement preset immediately and instead carries a **pending
`renovate/stability-days` status** until the age elapses. Renovate has no knob
that holds back branch creation for a pending-age replacement.

The consequence: the `ai` lane's CI-wait step sees `renovate/stability-days`
pending, polls for its full ~30-min budget on a gate runner, then times out
with no review — and re-burns that on **every rebase** across the 3-day window.
The PR cannot merge during that window regardless (the age status blocks it).

## Decision

Add a `defer` lane to `classify`. When a PR (on any trigger other than
`workflow_dispatch`) has a pending `renovate/stability-days` commit status on
its head, classify emits
`lane=defer` and exits. No downstream job runs for `defer` (the `ai-review`
and `ai-merge` jobs gate on `ai`/`fast` only), so no model is invoked and no
gate runner is allocated.

Re-entry is unchanged from the existing design: once the release ages, Renovate
rebases the branch, which fires a `synchronize` event and re-runs classify —
the status is now green, the PR falls through to its real `fast`/`ai` lane, and
review + merge proceed. `workflow_dispatch` bypasses the defer so a human can
force a review past the gate.

## Consequences

- **Positive:** No wasted model spend or ~30-min gate-runner holds on Renovate
  PRs that cannot merge yet; the waste no longer re-burns on every rebase.
- **Automated merge paths unchanged:** the age gate is still respected by every
  path that merges autonomously — Renovate's own automerge waits for
  `minimumReleaseAge`, and `ai-merge` is skipped in the `defer` lane. Nothing
  auto-merges a Renovate PR before its release ages.
- **Change to the human-merge path (accepted):** the org ruleset enforces this
  *workflow* as the required check, not `renovate/stability-days` as a required
  status context — and that context cannot be made org-required, since
  non-Renovate PRs never receive it and would hang forever. Previously a
  replacement PR sat in the `ai` lane, timed out after ~30 min, and the run went
  **red**, which incidentally blocked a manual UI merge. With `defer` the run is
  **green**, so a human *can* deliberately merge mid-window. This is acceptable:
  that block was an accidental byproduct of a wasteful failure, not a designed
  control; the age gate's purpose is to keep *autonomous* merges off
  freshly-published releases, and a human merging early is a conscious override.
- **Neutral:** During the defer window no advisory review comment is posted;
  it appears on the first run after the age clears (freshest possible head).
- **Scope:** Detection keys off the Renovate age status only, so it is
  inherently limited to Renovate PRs; it also covers the rare case where a
  normal update slips past `strict`.

## Alternatives considered

- **Short-circuit inside the `ai` lane's CI-wait step** instead of a new lane —
  smaller diff, but still spins up the gate runner each time. Rejected: routing
  in `classify` avoids allocating the gate runner at all.
- **Renovate-side fix** (disable replacement PRs, or drop `minimumReleaseAge`
  for replacements) — rejected: we want both the replacement and the release-age
  safety window; Renovate offers no setting to hold back a replacement branch.
