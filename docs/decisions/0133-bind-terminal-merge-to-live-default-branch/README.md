# 0133 — Bind terminal merge to the live default branch

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1069](https://github.com/Verjson/.github/issues/1069)
- **Extends:** [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md)
- **Related:** [#731](https://github.com/Verjson/.github/issues/731)

## Context

Generated publication checks can be exact for a pull-request head yet become stale
when the target default branch advances afterward. GitHub rulesets in the organization
do not currently require strict synchronized status checks. The publication producer
refetches and exact-leases its branch, but receive-pack cannot atomically require an
unchanged target branch when updating a separate publication branch.

Issue #1069 originally described strict synchronization after #731 as the preferred
resolution. That dependency is not a prerequisite for the issue's stated alternative:
#731 governs changelog-contract ruleset conformance, while terminal promotion can bind
the reviewed result to trusted live base metadata independently. Waiting would retain a
known stale-base window for every generated publication merge.

GitHub's pull-request merge interfaces accept an expected head OID but no expected base
OID. A base comparison and merge are therefore separate service requests. This decision
must not claim transaction-level compare-and-swap that GitHub does not provide.

## Decision

Terminal authorization reads pull-request metadata through the job's read-only
`GITHUB_TOKEN`, requires the PR to target the repository's API-derived default branch,
and captures the exact 40-character base commit OID. It separately resolves the trusted
default-branch Git ref and requires it to be a commit at that same OID. Only then may the
workflow emit authorization outputs and mint the exact-repository merge App token.

The terminal token step executes an immutable helper checked out from the executing
canonical workflow revision. Immediately before merge, that helper re-reads both the PR
and the default-branch Git ref through the repository-scoped App token. It requires the
PR to remain open, its head to equal the authorized head, its base name and OID to equal
the authorized default branch, and the live ref to remain the same commit. Any missing,
malformed, changed, or inconsistent value fails before merge. The helper then performs
the existing admin squash merge with `--match-head-commit`.

The trusted repository context remains the only source of `TARGET_REPO`; API-derived
metadata, not event payload or PR-head files, supplies the default branch and base OID.
The App token remains scoped to exactly that repository and retains only contents-write
and pull-requests-write. No PAT fallback, extra App permission, caller input, or
attacker-selected repository/ref is introduced.

## Trust boundaries

- Repository identity comes from `github.repository`, is grammar-checked, and is bound
  to the token action's exact owner/repository selectors before any merge authority is
  minted.
- Default-branch name, PR base OID, and live Git-ref OID come from authenticated GitHub
  API responses. A PR title, label, branch content, dispatch input, or generated caller
  cannot supply or widen them.
- Authorization uses only the read-only job token. The merge App token is delivered
  only to the terminal helper after authorization and cannot access Actions, checks,
  organization administration, secrets, packages, or deployments.
- The helper rejects a moved head, changed PR base, changed default-branch ref,
  non-commit ref, malformed OID, closed PR, or non-default base before invoking merge.
- `--match-head-commit` remains GitHub's atomic head comparison. GitHub exposes no
  equivalent expected-base argument, so a default-branch movement in the sub-request
  interval after the helper's last read is not transactionally excluded. Strict
  synchronized required checks remain the stronger eventual control when safely
  deployable; this workflow minimizes and fails closed on every observable base race.

## Consequences

- Terminal promotion refuses otherwise-green PRs whose reviewed base is no longer the
  live default-branch tip; the publication must be regenerated and checks rerun.
- The merge App performs two read operations immediately before its single write. That
  is a deliberate exception to ADR 0120's former one-operation wording and does not
  broaden credential delivery: all three operations address the already-bound PR/ref
  in the exact token repository.
- Adversarial CI exercises moved heads, stale PR bases, moved/malformed refs, wrong base
  names, closed PRs, malformed authorized OIDs, token isolation, and non-widenable App
  scope and permissions.
- Rollback disables terminal autonomous promotion or reverts this workflow and helper
  together. It must not restore a PAT or skip the live-base check.
