# 0008 — Merge gate auto-updates stale branches before review/merge

- **Date:** 2026-07-18
- **Issue:** Verjson/.github#41
- **PR:** Verjson/.github#42
- **Category:** CI / merge-gate behavior
- **Relationship:** Refines the cost-lane merge gate (`ai-review-merge.yml`); does
  not supersede a prior ADR.

## Context

The org `main-protection` ruleset does **not** enforce a strict "require branches
up to date before merging" policy, and the gate merges via the org-admin ruleset
bypass. So a PR that is `BEHIND` its base — clean, no conflict — merges even
though its green was computed against an **older** base-merge, and nothing
re-tests it against the current base. A green PR can therefore regress `main`
after merge when `main` advanced underneath it (a semantic-staleness gap that the
merge-commit ref, recomputed only on `synchronize`, does not close).

Two poor options existed:

- **Enable strict required-status-checks** — forces up-to-date, but *adds*
  friction: every PR is blocked until a human clicks "Update branch". That is the
  opposite of the goal (less manual toil), unless paired with automation.
- **Leave it as-is** — accept that green does not mean "green against current
  base," and that a conflicting (`DIRTY`) PR burns a full model review before the
  merge step fails on the conflict.

## Decision

Add a `freshness` job at the head of `ai-review-merge.yml`, upstream of
`classify`, that runs on every gate trigger and enforces base-freshness before
any model spend or merge:

1. **Behind base (clean)** → `PUT /pulls/{n}/update-branch` (merge the base in).
   The push fires `synchronize`, starting a **fresh run** that reviews/merges
   against the *current* base; the triggering run steps aside (`proceed=false`,
   so `classify`/`ai-review`/`ai-merge` skip). Green now means green against
   current base, with no human "Update branch" click.

   **"Behind" is detected via the compare API** (`GET /compare/{base}...{head_sha}`,
   `.behind_by > 0`), **not** `mergeStateStatus == BEHIND`. This is deliberate:
   because the ruleset is not strict, GitHub reports a behind-but-clean branch as
   `CLEAN`, and `mergeStateStatus` never says `BEHIND` — so keying on it would
   make this a no-op (observed on #40, which was behind and had to be updated by
   hand). The compare delta is protection-independent and always accurate.
2. **Conflicting** (`mergeable == CONFLICTING`, also protection-independent) →
   **hold, fail-closed**, and leave a single marker-guarded comment asking for a
   rebase. Fails fast, before any model spend.
3. **Renovate PRs** → left untouched; Renovate rebases its own PRs on its
   stability schedule, and the existing defer/fast lanes handle them.
4. **Up-to-date / other states** → proceed exactly as before.

This is **automated enforcement of an existing intent** (merge only what is
current and clean), not a change to *what* is allowed to merge. It is not a
sensitive-class change: no authn/authz, RBAC, IAM/OIDC, ruleset/branch-protection,
secret, or destructive surface is touched — the update-branch merge is
git-revertible.

## Consequences

- **A green gate means green against the current base.** The semantic-staleness
  window is closed for human/AI PRs without enabling a friction-adding
  up-to-date ruleset rule.
- **Conflicts surface fast and cheap** — held before review, with an actionable
  comment, instead of after a wasted model pass.
- **Cost:** one extra CI cycle per stale PR (the update-branch synchronize). Fast
  and Renovate lanes are unaffected; the freshness job itself is cheap
  deterministic bash on the same pool as `classify`.
- **No new secrets or permissions:** reuses `ORG_ADMIN_TOKEN` (already used for
  cross-repo merge) for the update-branch push and the comment.
- **Renovate boundary preserved:** the gate never fights Renovate's own rebase
  cadence.
- **Failure mode:** if `update-branch` cannot apply (race / already current), the
  job proceeds rather than blocking — the normal gate logic (and, ultimately, the
  squash-merge) remains the backstop.
