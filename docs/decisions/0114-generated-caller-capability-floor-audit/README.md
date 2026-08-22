# 0114 — Detect consumer generated-caller pins that predate an assumed capability

- **Date:** 2026-08-22
- **Status:** Accepted
- **Issue:** [#933](https://github.com/Verjson/.github/issues/933) (part 2; part 1 — bumping `toquorum`'s stale pin — landed separately in `Verjson/toquorum#636`)

## Context

Every generated caller workflow this repo produces (`scripts/gen-gate-rearm-caller.sh`,
`scripts/gen-ai-review-caller.sh`, `scripts/gen-privileged-merge-caller.sh`,
`scripts/gen-changelog-caller.sh`, `scripts/gen-renovate-compatibility-caller.sh`) pins
itself to an immutable commit SHA of this repo's canonical contract, by design, so a
consumer's CI stays reproducible against a reviewed contract version rather than a
moving `main`.

That design has a gap: when the canonical contract gains a capability that an
organization-wide variable then assumes every adopter has, a consumer whose generated
caller predates that capability breaks with no signal pointing at the pin. This
happened concretely: `AI_REVIEW_PRIMARY_PROVIDER` moved org-wide to `deepseek` on
2026-08-16, but `toquorum`'s `gate-rearm.yml` was pinned to commit
`a6b3ccc0590f4fcfdacd7818279ab3eea6b30155` (2026-08-10, #722) — a commit that predates
`23f641822d1fdf4787a46f0b55f24a755b8a73ae` (also 2026-08-10, #732/#734), the commit that
first accepts `deepseek` as a review provider. Every AI-review arm attempt in `toquorum`
failed closed with `unsupported review provider` from 2026-08-16 forward, silently,
until someone reproduced it live. The same failure class recurred independently in
`verjson-authn` (issue comment, 2026-08-19, across all four of its generated callers,
not just `gate-rearm.yml`), `viager-app` (#976), and `verjson-cli-cloud` (#977, a
different capability: the changelog contract's Renovate default-source-link
acceptance from #927). Four independent consumers hitting the same failure class in one
week is the signal this is systemic, not a one-off pin that happened to go stale.

This is explicitly the still-open half of #933: part 1 (bumping `toquorum`'s pin) is
done; this ADR is the "dedicated design pass" the repo's own tracking notes said part 2
needed.

## Decision

### What "staleness" means

A consumer's generated-caller pin is **stale for capability X** when its pinned
contract SHA is **not a git ancestor** of the commit that introduced capability X, and
that pin's generator is one X's `generators` list names as needing X.

Concretely: `git merge-base --is-ancestor <introduced_at> <pinned_sha>` decided against
**this repository's own history** — `Verjson/.github` is the canonical source every
generated-caller pin is drawn from, so no external clone, API call, or separate index is
needed to answer the ancestry question. This is strictly cheaper and more precise than
comparing dates or PR numbers (same-day commits can still be non-ancestors of each other,
as the `toquorum` incident shows: `a6b3ccc` and `23f6418` are both dated 2026-08-10 but
neither is an ancestor of the other).

### Representing "capability X was introduced at commit Y" as data

Extend this repo's existing pattern for org-variable-tracking config — the
`schema_version`-tagged JSON files already checked into `config/`, e.g.
`config/ai-review-required-workflow-rollout.json` — rather than inventing a new
mechanism. A new file, `config/capability-floors.json`, holds an array of capability
facts:

```json
{
  "schema_version": 1,
  "capabilities": [
    {
      "id": "ai-review-deepseek-provider",
      "description": "... human-readable explanation ...",
      "introduced_at": "23f641822d1fdf4787a46f0b55f24a755b8a73ae",
      "issue": 933,
      "generators": [
        "scripts/gen-gate-rearm-caller.sh",
        "scripts/gen-ai-review-caller.sh",
        "scripts/gen-privileged-merge-caller.sh"
      ],
      "assumed_by_org_variable": {"name": "AI_REVIEW_PRIMARY_PROVIDER", "value": "deepseek"}
    }
  ]
}
```

- `introduced_at` must be a 40-character commit SHA reachable in this checkout — a
  capability whose introducing commit can't be resolved locally is a config error, not a
  silent no-op.
- `generators` lists which of `scripts/gen-*-caller.sh` produce a caller that needs this
  capability. A pin naming a generator no capability tracks is not an error — most
  generators have no tracked floor yet, and that is the expected steady state, not a gap
  to force-fill.
- `assumed_by_org_variable` is optional (`null` when the capability isn't driven by an
  org variable at all, as with the changelog source-link fix — the contract's accepted
  shape simply changed, and every consumer needs the new shape regardless of any
  variable). When present, it documents *why* this became universal rather than merely
  available, for a human reading the finding.
- Entries are added in the same PR that ships the capability (or a fast-follow), the same
  way `NEXT/` fragments and ADRs are added alongside the change they document — this
  keeps the fact and the capability from drifting apart, rather than requiring a
  separate audit to reconstruct history after the fact.

This file carries no mutation authority and selects no ruleset or credential, so it does
not need the human-owned-dial treatment `ai-review-required-workflow-rollout.json` and
`.telemetry/rework-thresholds.json` get (ADR 0006) — it is reviewed like any other PR
changing `config/`.

### How it's checked

Split into two stages, deliberately not built as one PR:

**Stage A — local staleness computation (this PR).** `scripts/capability-floor-audit.py`
takes `config/capability-floors.json` and a **pins snapshot** — a JSON array of
`{repo, generator, pinned_sha}` records — and reports which pins are stale, which are
current, and which name a `pinned_sha` this repository's history doesn't recognize at
all (a distinct, always-reportable failure mode: a pin to a SHA that isn't in
`Verjson/.github`'s history is not really "stale", it's unresolvable, and conflating the
two would hide a different bug). It is pure, read-only, and takes no live GitHub
network dependency — it only shells out to local `git`. Exit code is 0 by default
(report-only, matching the `RCA_APPLY=false` default posture in
`scripts/required-checks-rollout.sh`); `--fail-on-stale` is available for a caller that
wants a hard signal.

**Stage B — live pin discovery (follow-up, not in this PR; see below).** A
scheduled/dispatched workflow that, in the spirit of
`scripts/required-checks-rollout.sh`'s "discover live repos, audit read-only, report,
never auto-mutate" pattern, reads each known consumer repository's generated caller
workflow file via the GitHub API, extracts the pinned SHA from its `uses:
Verjson/.github/...@<sha>` line, assembles the pins snapshot Stage A consumes, and
publishes the resulting report (e.g. as a workflow summary, and/or a comment on the
tracking issue). This stage needs org-wide read-only reach into every consumer's
`.github/workflows/*.yml` — the same read posture (metadata + contents read, no write)
`ai-review-required-workflow-audit.py`'s dedicated App already models for a related
problem — and a maintained list of which repositories to check (this org already has a
precedent for a human-owned "which repos does this observability cover" list:
`.telemetry/rework-thresholds.json`'s `repos` array, refreshed manually per ADR 0113).

### What it does when it finds staleness

**Report-only**, full stop, for this first version. No auto-regeneration of a consumer's
caller, no auto-opened PR, no auto-issue-creation, no repository dispatch into the
consumer. `toquorum`'s own incident shows why a wrong caller here is more expensive than
a wrong finding: a generated caller carries `actions:write` and other privileged scopes
in a consumer repo, and any mechanism that could touch it needs at least the scrutiny
`ADR 0109`'s observe-first control plane gave Renovate compatibility, and likely more,
since this would be pushing to *other* repositories, not just reading them. That is a
larger and separately-reviewable decision; this ADR does not authorize it.

### Rollout and human-gate considerations

- Stage A ships report-only with no scheduled trigger of its own — it's a script a human
  or a future Stage B workflow invokes with an explicit pins file. There is nothing to
  gate: it has no side effects to roll back.
- Stage B (future), once built, follows this repo's existing pattern for org-wide
  observability: a dedicated read-only credential scoped to exactly the repos and paths
  it needs (mirroring `ai-review-required-workflow-audit.py`'s App-based read scope), a
  scheduled or `workflow_dispatch` trigger (not a merge-path gate — this must never be
  able to block or slow down an unrelated consumer's PR), and a human decides what to do
  with a stale finding. Given four independent live incidents already, escalating a
  stale finding to a visible per-repo issue is a reasonable eventual target, but that is
  itself a mutation (issue creation) and needs its own explicit authorization step
  the same way `ADR 0109` withheld automatic issue creation from the compatibility
  reconciler's first rollout.
- `config/capability-floors.json` entries are ordinary reviewed config, not a
  human-owned dial in the ADR 0006 sense — nothing downstream of it mutates anything, so
  the review bar is "is this fact correct", not "does this change how much verification
  effort AI-authored work receives".

## Consequences

- A capability introduced in this contract that an org variable subsequently assumes is
  universal can now be checked against a supplied consumer-pin snapshot without manual
  SHA archaeology (the kind performed by hand across four incidents to produce this ADR).
- The mechanism cannot yet discover consumer pins itself — until Stage B ships, someone
  (human or an ad hoc script) has to supply the pins snapshot. This is a known, explicitly
  scoped limitation, not an oversight: building live cross-repository discovery from
  scratch is a materially larger and more sensitive PR (new credential scope, a
  maintained repo list, a schedule, a publication surface) than a pure local
  ancestry-check script, and forcing it into this PR would mean shipping the riskier half
  half-reviewed alongside the ADR that is supposed to justify it.
- `config/capability-floors.json` can drift from reality if a capability-introducing PR
  forgets to add an entry. That failure mode is silent under-detection (a real staleness
  goes unflagged), which is strictly better than the status quo (all staleness goes
  unflagged) and is the same class of gap `deterministic_required_status_contexts` in
  `config/ai-review-required-workflow-rollout.json` already accepts for a related
  problem — worth a future lint (e.g. "generator scripts changed in this PR but no
  capability entry was added") but not required to ship this increment.

## Follow-up scope on issue #933 (do not open a new issue)

The next implementation PR against this ADR should build Stage B:

1. A read-only credential (dedicated App or narrowly scoped token) that can read
   `.github/workflows/*.yml` contents across a maintained list of known consumer
   repositories — start from `.telemetry/rework-thresholds.json`'s `repos` list plus the
   repositories already named in this issue's evidence (`toquorum`, `verjson-authn`,
   `viager-app`, `verjson-cli-cloud`) as the initial maintained set, refreshed the same
   manual way ADR 0113 refreshes the rework-telemetry list.
2. A scheduled/dispatched workflow that, for each known consumer and each
   `scripts/gen-*-caller.sh` output path it generates, extracts the pinned SHA from the
   `uses: Verjson/.github/...@<sha>` line and assembles the pins snapshot
   `scripts/capability-floor-audit.py --pins` consumes.
3. A publication step for the report — a workflow summary at minimum; a comment update on
   a tracking issue is a reasonable next step but should be scoped and reviewed
   separately, matching how ADR 0109 withheld automatic issue creation until its
   observe-first phase proved out.
4. Tests registered in `scripts/actions-ci-groups.tsv`, per this repo's convention, for
   every new behavioral surface Stage B adds.

Auto-regeneration or auto-PR-opening for a stale consumer caller is explicitly **not**
in scope for that follow-up either — it is a larger, separately-justified decision on top
of a working, trusted report stage, not an assumed next step.
