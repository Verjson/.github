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
  (fine-grained PAT / app token) secret to widen coverage — see
  [Provisioning `REWORK_RECONCILE_TOKEN`](#provisioning-rework_reconcile_token-org-admin-runbook).
  Repos the token cannot read are **surfaced** as a data-quality warning, never
  silently zeroed.
- **Locally:** `scripts/ci-telemetry/rework-reconcile.sh .telemetry/rework-thresholds.json`
  (set `REWORK_AGG_OUT=path.json` to also dump the raw aggregate).

## Provisioning `REWORK_RECONCILE_TOKEN` (org admin runbook)

Minting a fine-grained PAT or GitHub App installation token has no API — it is a
human action in the GitHub UI. Everything else below is copy-paste. Issue **#157**
tracks the outstanding provisioning; until it is done the scheduled run falls back
to this repo's `GITHUB_TOKEN` and the other configured repos report as degraded —
as `commit data unavailable` when commit reads are denied, or as
`skipped … unreadable repo(s)` when the bulk pull-request read fails.

### 0. Org precondition

Fine-grained PATs must be **enabled for the Verjson organisation**, and this token
must be **approved by an org owner** before it can read org-owned repositories
(Organisation settings → Personal access tokens). Without both, step 1 produces a
token that authenticates but reads nothing, and the reconciler stays degraded with
no obvious cause.

### 1. Permissions — exactly three, all read

Derived from what `scripts/ci-telemetry/rework-reconcile.sh` actually calls, not
from a guess:

| Repository permission | Level | Why — the call that needs it |
|---|---|---|
| Metadata | Read-only | Mandatory on every fine-grained token; resolves each `--repo` |
| Pull requests | Read-only | `gh pr list --json number,title,body,mergedAt,createdAt,files,labels,reviews` |
| Contents | Read-only | `gh api repos/<repo>/commits?since=…` — the squash-commit AI-authorship signal |

**Grant nothing else.** In particular **no write scope of any kind**, and no
`Issues`: the weekly issue is opened by a *separate* step that uses
`secrets.GITHUB_TOKEN`, so this credential never needs write anywhere. A token with
write access to pull requests, contents, or checks/statuses would put the
reconciler in a position to influence a merge or verification gate, which is
precisely the boundary **ADR 0006** (observe-and-report) forbids. The workflow's own
`permissions:` block (`contents: read` + `issues: write`) is not a backstop for this
secret — a PAT carries its own grants, so least privilege must be set at mint time.

Use a **fine-grained PAT**. A GitHub App installation token is organisation-owned
rather than tied to an individual's account, but it is not a drop-in here:
installation tokens expire after about an hour, and
[`.github/workflows/rework-reconcile.yml`](../.github/workflows/rework-reconcile.yml)
consumes the secret verbatim with no minting step. Moving to the App route means
storing the App ID and private key and adding `actions/create-github-app-token` to
the workflow — out of scope for #157, worth revisiting at the first PAT rotation.

### 2. Repository access — the eight repos in the config

Scope the token to *only* these (`.repos[]` of
[`.telemetry/rework-thresholds.json`](../.telemetry/rework-thresholds.json) — that
file is the source of truth; re-read it if it has since changed). Do **not** grant
"all repositories":

```
Verjson/.github
Verjson/catalog-api
Verjson/catalog-ui
Verjson/catalog-worker
Verjson/viager-app
Verjson/viager-infra
Verjson/verjson-authn
Verjson/verjson-authz
```

### 3. Install the secret

```sh
gh secret set REWORK_RECONCILE_TOKEN --repo Verjson/.github
# paste the token at the prompt — never pass it as an argument (shell history)
# and never commit it or paste it into an issue/PR
```

### 4. Verify

```sh
gh workflow run rework-reconcile.yml --repo Verjson/.github
sleep 5  # dispatch registration lags; without this the query below can return
         # the previous *scheduled* run and you verify a stale green
gh run watch "$(gh run list --workflow rework-reconcile.yml --repo Verjson/.github \
  --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --repo Verjson/.github
```

Then open the issue the run created and confirm the report body has **no**
`commit data unavailable` line (emitted at `scripts/ci-telemetry/rework-reconcile.sh:111`)
and no `skipped … unreadable repo(s)` line. A clean report starts straight at the
`## AI-work rework — weekly reconciler` heading with no `⚠️ Data quality` banner.

If a repo is still listed, the token is missing that repo (step 2) or missing
Contents/Pull requests read (step 1) — not a script bug. A degraded read is
surfaced, never silently zeroed, so a partial report is safe to act on as *partial*.

### 5. Renewal

A fine-grained PAT expires. Put the expiry in the org calendar and re-run steps 3–4
to rotate; the first degraded weekly report after an expiry is the backstop signal.

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
