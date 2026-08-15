# 0102 — Require explicit impact for new changelog fragments

- **Date:** 2026-08-15
- **Issue:** [#800](https://github.com/Verjson/.github/issues/800)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md)
- **Supersedes in part:** [ADR 0071](../0071-changelog-impact-governs-version-bumps/README.md)
- **Category:** Release architecture
- **Status:** Accepted

## Context

ADR 0071 made an omitted `impact` mean `patch` to preserve existing fragments
during adoption. That compatibility default also accepted newly authored
fragments silently. A feature could therefore pass pull-request validation and
later force the release engine to reject the correct minor version because the
durable fragment had already encoded an implicit patch.

Commit subjects cannot repair this reliably: squash merge can rewrite them, and
one pull request can contain fragments with different release impact. The
fragment is the durable unit consumed by release automation.

## Decision

Every newly added canonical fragment declares exactly one of `impact: major`,
`impact: minor`, or `impact: patch`. `changelog.py validate` accepts pull-request
base and head revisions, identifies fragments added or renamed into `NEXT/`, and
rejects omission with a diagnostic naming all three permitted values.

The historical patch fallback remains only for fragments already present at the
base revision. Release and rendering continue to accept those entries, and
released `CHANGELOG/<version>.md` snapshots remain immutable prose rather than
fragment input.

Adopters receive a bounded migration window through 2026-08-29 UTC. The two
canonical required-check workflows pass
`--allow-missing-impact-through 2026-08-29`; after that date the same pinned
engine enforces explicit impact without requiring another caller regeneration.
Generated adopter artifacts continue to share one immutable contract pin.

## Consequences

- Release intent is reviewed where it is authored, before a snapshot or version
  proposal can depend on a mistaken default.
- Existing unreleased fragments and immutable snapshots are not rewritten or
  reinterpreted.
- Old unmerged branches have a dated window to add metadata, while the policy
  cannot remain disabled indefinitely.
- Release impact remains independent of Conventional Commit subjects and is
  still evaluated only across the selected fragment set.

## Rejected alternatives

- **Infer impact from commit subjects.** Squash merge and mixed-impact pull
  requests make the subject an unstable, lossy input.
- **Require impact on every current fragment immediately.** That turns contract
  adoption into a bulk rewrite and breaks unmerged branches created under ADR
  0071.
- **Keep an undated opt-out.** A permanent compatibility flag lets repositories
  silently retain the defect this decision closes.
