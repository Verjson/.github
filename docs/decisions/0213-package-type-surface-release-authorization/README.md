# 0213 — Package type-surface rulesets use the release App only

- **Date:** 2026-10-01
- **Status:** Accepted
- **Issue:** [#1673](https://github.com/Verjson/.github/issues/1673)
- **Category:** rulesets, release authorization, package publication — sensitive class

## Context

The canonical node release workflow publishes an immutable changelog snapshot
and tag with one atomic push to the default branch. A type-surface ruleset is
still required because package exports are a compatibility contract. GitHub
cannot restrict a ruleset bypass to only changelog paths, so each package
type-surface ruleset must have one deliberate exception: the repository-scoped
`release-authorization` App (`4583107`).

The fleet was inconsistent. Identity-contracts allowed an organization
administrator and the merge App in addition to the release App; lifecycle had
no release bypass; authn had already adopted the release App; authz ran the
type-surface check without an enforcing ruleset.

## Decision

The organization-owned `config/package-type-surface-rulesets.json` is the
reviewed source of truth for managed package rulesets.
`scripts/package-type-surface-ruleset.py` renders and audits live images,
refuses unexpected preimages, requires the explicit
`APPLY-PACKAGE-TYPE-SURFACE-RELEASE-1673` acknowledgement for mutation, and
verifies the complete postimage. It never reads or prints a private key.

Every managed package type-surface ruleset has exactly this bypass actor:

```json
[{"actor_type":"Integration","actor_id":4583107,"bypass_mode":"always"}]
```

No organization administrator, merge App, Renovate App, or other integration
is a type-surface bypass. The private key remains confined to the canonical
snapshot job. The existing release-App canary remains the operational proof
that the pinned App token can perform the atomic release operation; the nightly
organization conformance workflow audits organization and package rulesets.

## Rollout and rollback

For each package, read the live ruleset and compare the exact reviewed
preimage, re-read immediately before mutation, write only the rendered desired
image, and read back the complete postimage. A missing authz ruleset is created
disabled, verified, activated, and verified again. The canary must pass before
the release is dispatched.

If a postimage or canary check fails, stop and preserve the live state for
inspection. Rollback restores the reviewed preimage through the same explicit
acknowledgement path; it never blindly overwrites a changed ruleset.
