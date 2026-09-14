# 0176 — No approved organization custody for environment-only App keys

- **Date:** 2026-09-14
- **Issue:** [#1326](https://github.com/Verjson/.github/issues/1326)
- **Category:** credential custody and organization secret scope

## Context

[ADR 0166](../0166-environment-only-app-private-keys/README.md) confines the review,
merge and release App private keys to main-only repository environments, and
[#1332](https://github.com/Verjson/.github/pull/1332) stopped the legacy adopter
bootstrap from writing them as organization secrets. The organization secret-scope
policy is the second surface that routes those keys. It still recorded
`AI_REVIEW_APP_PRIVATE_KEY` and `MERGE_APP_PRIVATE_KEY` as ordinary organization
credentials with an approved steady-state visibility target, and
`scripts/org-secret-scope-audit.py` printed `secret-scope-policy=conformant` whenever
live metadata matched that target.

That combination is a documented success path for a broad App-key copy. An operator
could widen or recreate a broad copy of an environment-only key and the audit would
report conformance, because readable organization secret metadata proves only a name
and a visibility, never exclusive environment storage. An alias such as
`SHADOW_APP_PRIVATE_KEY` was likewise unclassified, mirroring the alias gap the
bootstrap closed.

## Decision

Organization custody of an App private key must be declared, and it is unavailable to
the roles ADR 0166 governs.

- Each policy entry whose name ends in `_APP_PRIVATE_KEY` must declare `custody`. Only
  `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and
  `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY` may declare `organization`; those roles
  keep their current contract until an explicit custody decision lands. Any other
  App-key name fails closed as an unrecognized role, with no live metadata consulted.
- `AI_REVIEW_APP_PRIVATE_KEY`, `MERGE_APP_PRIVATE_KEY` and `RELEASE_APP_PRIVATE_KEY`
  may appear only as `environment-only-migration-residue`, and a residue entry must
  record a `withdrawal` contract path, tracking issue and record date.
- While any residue entry exists the audit reports
  `secret-scope-policy=withdrawal-pending` with the residue names. `conformant` is
  reserved for a policy with no environment-only residue at all.
- Custody classification is structural: it reads names, declared roles and the policy
  document, never a secret value, and it runs before any GitHub read so a malformed or
  over-broad policy fails even when live metadata is unavailable.

This decision amends [ADR 0088](../0088-auditable-organization-secret-scope/README.md);
that record's audit contract stands, with the approved-target vocabulary narrowed for
these three roles.

## Consequences

The policy file can no longer express an approved broad target for an
environment-only App key, so recreating one is a policy failure rather than a silent
conformance pass. Existing broad copies are untouched: the exit status for the current
Verjson policy is unchanged, and the audit stays read-only. Withdrawal of those copies
remains owner work tracked by [#1285](https://github.com/Verjson/.github/issues/1285);
this record does not authorize deleting or rotating a live key. The visible cost is a
status string that stays `withdrawal-pending` until that migration finishes, which is
the intended standing signal.
