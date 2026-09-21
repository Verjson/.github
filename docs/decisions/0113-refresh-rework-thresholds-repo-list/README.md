# 0113 — Refresh the rework-telemetry repo list to activity-ranked repos

- **Date:** 2026-08-21
- **Issue:** [#980](https://github.com/Verjson/.github/issues/980)
- **Category:** AI governance / verification calibration — sensitive-class,
  amends the human-owned dial established by [ADR 0006](../0006-ai-rework-observe-and-report/README.md)

## Context

`.telemetry/rework-thresholds.json`'s `repos` list (`catalog-api`, `catalog-ui`,
`catalog-worker`, `viager-app`, `viager-infra`, `.github`, `verjson-authn`,
`verjson-authz`) was fixed at the reconciler's original rollout. It has gone
stale: `catalog-api`/`ui`/`worker` and `viager-app`/`infra` have had little to no
activity for weeks, while the reconciler's own weekly reports (#966, #960, #978)
show those repos permanently in the "unreadable" data-quality banner — some of
that is a separate credential problem (#157), but part of it is simply that the
list no longer names where the org's engineering activity, and therefore the
AI-authored work this telemetry exists to calibrate, actually is.

ADR 0006 makes this file's `repos` list a human-owned dial precisely because it
governs how much AI-authored work gets measured and where verification effort
gets calibrated — the AI must not change it unilaterally. This revision is made
at the user's explicit request, with authority to determine the methodology and
document the resulting decision, in the same conversation that requested it.

## Methodology

1. **Universe:** every non-archived repository in the `Verjson` org
   (`gh api orgs/Verjson/repos --paginate`, `archived == false`) — 94 repos at
   the time of this ranking, 8 of which are genuinely empty (`HTTP 409 Git
   Repository is empty`, so 0 activity by construction).
2. **Window:** 6 weeks, `2026-07-10T00:00:00Z` through the ranking date
   (`2026-08-21`), matching the window size this refresh's request specified.
3. **Signal:** commits on each repo's default branch in that window
   (`GET /repos/{repo}/commits?since=...`, paginated), filtered to drop
   bot-authored commits — any commit whose author login (falling back to the
   raw commit-author name when GitHub can't resolve a login) matches
   `[bot]$`, `^dependabot$`, `^renovate$`, or contains `github-actions`
   (case-insensitive). This removes Renovate, Dependabot, and
   `github-actions[bot]` noise so the ranking reflects human/AI-assisted
   engineering activity, not dependency-bump volume.
4. **Metric:** count of surviving (non-bot) commits per repo in the window.
   Ranked descending; top 10 selected.
5. **Explicit exclusion:** `Verjson/verjson-agents` (rank 8 by raw count, 143
   human-filtered commits) is excluded regardless of rank — it is tooling used
   to build and orchestrate AI agents across the org, not a shipped product
   whose rework this telemetry is meant to calibrate. Decided in the requesting
   conversation, recorded here for the durable rationale.
6. **Repo count:** 10, per the requesting conversation's resolution (narrowed
   from the prior 8-repo list, which had drifted to include repos with no
   current activity).

### A methodological note on `SelfPublish-Internal`

This repo is a fork (`lightningleap/bellwether-nextJs`). Its commit count
reflects commits reachable from its own default branch by its own confirmed org
members and collaborators (verified via `gh api
repos/Verjson/SelfPublish-Internal/collaborators`, cross-checked against `gh api
orgs/Verjson/members`) — not upstream activity synced in passively. It is
included on the same objective ranking basis as every other repo; flagged here
only so a future reader isn't surprised to see a fork in the list.

## Decision

Replace `.telemetry/rework-thresholds.json`'s `repos` list with the top 10 repos
by the ranking above:

| Rank | Repo | Human-filtered commits (6wk) |
|---|---|---:|
| 1 | `Verjson/nomico` | 504 |
| 2 | `Verjson/.github` | 455 |
| 3 | `Verjson/toquorum` | 202 |
| 4 | `Verjson/SelfPublish-Internal` | 183 |
| 5 | `Verjson/catalog` | 163 |
| 6 | `Verjson/verjson-cli-cloud` | 162 |
| 7 | `Verjson/verjson-ai` | 159 |
| 8 | `Verjson/AiB` | 134 |
| 9 | `Verjson/verjson-authn` | 112 |
| 10 | `Verjson/verjson-observability` | 87 |

Repos just outside the cutoff, for context on how close the boundary is:
`Verjson/verjson-payments` (85), `Verjson/verjson-infra` (85, tied),
`Verjson/verjson-authz` (74). None of the prior list's `catalog-api`,
`catalog-ui`, `catalog-worker`, `viager-app`, or `viager-infra` reached even
this second tier in the current window.

`window_days` (the reconciler's own 7-day rolling report window),
`min_sample`, `rework_rate_warn` floors, `canary_pct`, and `circuit_breaker`
are unrelated dials and are unchanged by this decision.

## Consequences

- The reconciler now measures rework where the org's engineering activity
  currently is, rather than against repos that have gone quiet.
- `verjson-authz` and `verjson-payments` drop out of measurement despite being
  in a prior candidate proposal — both sit just below the top-10 cutoff in this
  window and can re-enter on a future refresh if their activity picks up.
- This is a one-time/periodic manual refresh, not a live query — the list will
  drift again as activity shifts. A follow-up automation to keep it current is
  explicitly out of scope for this ADR (see the open discussion on redesigning
  the rework metric itself toward line-churn/hotspot detection, which was
  raised in the same conversation as a separate, larger design problem and is
  not addressed here).
- Because this file is the human-owned dial under ADR 0006, this ADR is the
  durable record of *why* the list changed and *how* it was computed, so a
  future reviewer isn't left reverse-engineering a git diff.
