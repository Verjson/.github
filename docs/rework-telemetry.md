# AI-work rework telemetry (reconciler MVP)

A weekly, retrospective reconciler that measures **rework** on merged PRs —
reverts, fix-follows-merge, and pre-merge friction — split by `change_category`
and `ai_authored`, to calibrate how heavily each category of work is verified
("trust but verify" with data, not vibe). Issue **#33**; governance **ADR 0006**
(observe-and-report) and **ADR 0007** (adaptive verification by blast radius).

This is the **MVP shortcut** from the ticket: a pure GitHub-API job that opens a
weekly **summary issue**. It has no OTLP dependency (the shared collector is
dormant / not routable from the runners — see [`ci-telemetry.md`](./ci-telemetry.md)).
The aggregate it produces already conforms to `ReworkTelemetryPayload`
(verjson-observability#49), so the later OTLP emit path is additive.

## Governance boundary (read this first)

Per **ADR 0006**, the AI must not own the mechanism that decides how much
AI-authored work is trusted. Concretely:

- **The dial is human-owned.** The thresholds and repo list live in
  [`.telemetry/rework-thresholds.json`](../.telemetry/rework-thresholds.json).
  The reconciler only **reads** it. Changing a floor is a human edit.
- **Observe-and-report only.** The job's single write is `gh issue create`. It
  **proposes** (flags buckets over their floor); it never mutates a merge or
  verification gate. Its workflow permissions are `contents: read` + `issues:
  write` — by grant it *cannot* touch a PR. This is asserted in
  `scripts/ci-telemetry/rework-reconcile-trigger.test.sh`.
- **Small-N honesty.** A bucket is flagged only when `sample_size >=
  min_sample`; every row shows its sample size; low-precision signals are
  excluded from the headline rate.

## How it works

Two cheap calls per repo, joined locally (no per-PR round-trips):

1. `gh pr list --state merged --search "merged:>=<start>"` for cheap fields
   (title, body, files, labels, reviews). It deliberately **omits `commits`** —
   that field's nested `authors` connection blows GitHub's GraphQL node ceiling
   at any useful `--limit`.
2. `gh api repos/<repo>/commits?since=<start>` on the default branch. The org
   squash-merges, so each merged PR is one commit whose message carries the
   `(#NN)` back-reference and the `Co-Authored-By: Claude` trailer — that is the
   AI-authorship signal.

Then three pure, unit-tested stages:

| stage | script | role |
|---|---|---|
| classify | `rework-classify.sh` | per-PR `change_category`, `ai_authored`, `rework_signal` |
| aggregate | `rework-aggregate.sh` | one `ReworkTelemetryPayload` per `(category, ai_authored)` |
| report | `rework-report.sh` | the Markdown issue body + threshold proposals |

`rework-reconcile.sh` is the only IO layer; the three stages are pure filters
driven by fixtures in the matching `*.test.sh` files.

### Attribution tiers

Ranked, never blended into one number (ticket guardrail):

- **revert** (high) — `This reverts commit` / `Revert "…"`.
- **explicit_fix_ref** (high) — a conventional `fix:`/`revert:` PR that
  references an issue (`Fixes/Closes/Resolves #N`).
- **fix_same_area** (medium) — any other conventional `fix:`/`revert:`. This is
  the **MVP approximation** of the ticket's "fix touching the same top-level area
  within N days"; tightening it to a real cross-PR area/time match is a follow-up.
- **post_merge_ci_fail** (objective) — reserved in the schema; **not populated by
  the pure-API MVP** (needs post-merge main-CI attribution). Always `0` today.
- **file_overlap_only** (low) — directional; **excluded from the headline rate**
  and reported in its own column. Not computed by the MVP (`0`).

`change_category` is assigned **sensitivity-first** (auth/migration win over
infra/app/ci/docs) so a sensitive change is never masked by a lower-risk match.

## Running it

- **Schedule:** Mondays 06:17 UTC (`.github/workflows/rework-reconcile.yml`), plus
  `workflow_dispatch`.
- **Cross-repo reads** need a token with org read scope. The default
  `GITHUB_TOKEN` only covers this repo; set a read-only `REWORK_RECONCILE_TOKEN`
  (fine-grained PAT / app token) secret to widen coverage. Repos the token cannot
  read are **surfaced** as a data-quality warning, never silently zeroed.
- **Locally:** `scripts/ci-telemetry/rework-reconcile.sh .telemetry/rework-thresholds.json`
  (set `REWORK_AGG_OUT=path.json` to also dump the raw aggregate).

## Known MVP limitations (honest boundary)

- `post_merge_ci_fail` and `file_overlap_only` are schema-present but not
  populated — deterministic `0`.
- `commits_after_first_review` is `0` under squash-merge (individual commits are
  collapsed); the friction median degrades gracefully.
- AI-authorship depends on the squash commit reaching the default branch with the
  `(#NN)` ref; PRs merged by a non-squash path are treated as non-AI (directional).
- `since` on the commits call is committer-date, an approximation of merge time.

All of these fail **toward less confidence, not false precision**, consistent with
ADR 0007's "fail toward more review on low signal."
