# 0159 — Graduate packages to `v1` by evidence, not by organization-wide wave

- **Date:** 2026-09-01
- **Status:** Accepted
- **Issue:** [#1088](https://github.com/Verjson/.github/issues/1088)
- **Supersedes:** [ADR 0137](../0137-cut-v1-0-0-across-pre-1-0-packages/README.md)
- **Related:** [ADR 0038](../0038-canonical-changelog-contract/README.md), [ADR 0108](../0108-bound-package-retention-to-three-stable-releases/README.md)

## Context

ADR 0137 required every pre-`1.0.0` `@verjson/*` package to join one coordinated release
wave. The readiness work exposed useful defects, but the universal release objective does
not follow from them. A package with no stable consumer contract, little active use, or an
API still being discovered gains little from making an irreversible `1.0.0` promise.

The organization still needs a consistent meaning for `1.0.0`. Without one, packages may
graduate for cosmetic consistency, while packages that would materially benefit from
stable SemVer ranges can remain indefinitely below `1.0.0`.

## Decision

End the organization-wide release wave. A pre-`1.0.0` package graduates independently
only when its owning repository records evidence for all of these conditions:

1. **A stability promise has a consumer.** At least one maintained production, paid,
   public, or in-organization runtime consumer needs a stable API range. Dev-only use can
   qualify when incompatible upgrades impose recurring organization-wide CI work, but a
   dependent count alone does not.
2. **The intended supported surface is known.** The owner can state which exports,
   commands, schemas, or protocols are stable for the major and which remain experimental.
3. **The readiness contract passes.** The package clears
   [`docs/v1-readiness/README.md`](../../v1-readiness/README.md) at an immutable SHA, with
   evidence in its repository. A package may stay at `0.x` when the bar is not worth its
   current value; failing the bar no longer blocks unrelated packages.
4. **Consumer migration is bounded.** The owner inventories runtime, peer, exact, and
   lockfile consumers; identifies the releases needed to widen their ranges; and sequences
   those releases before retention can remove their last satisfiable version.
5. **Release ownership exists.** A named repository owner accepts post-`1.0.0` SemVer
   responsibility and can ship a correction. An unowned or dormant package does not
   graduate to manufacture a maintenance promise.

Meeting these conditions makes a package eligible, not mandatory. Its release remains an
explicit, repository-owned dispatch. Readiness issues may be closed when a package either
graduates or records that it intentionally remains at `0.x`; they are no longer
prerequisites of one central wave.

`@verjson/eslint-config`, already released above `1.0.0`, remains there. This decision does
not roll it back. No other package is selected merely because it appeared in ADR 0137's
former eighteen-package list.

## Consequences

- `#1088` becomes the decision and dependency-graph cleanup tracker, not a release tracker
  for a fixed package count.
- Package owners can prioritize graduation where stable propagation has real consumer
  value without making low-use or experimental packages promise stability prematurely.
- Version numbers across the organization remain intentionally non-uniform.
- The readiness bar remains canonical and reusable, but its language and evidence apply to
  one candidate package at a time.
- Cross-package sequencing is derived for each selected graduation; ADR 0137's historical
  full-wave layers are not an active release plan.

## Migration

1. Remove the remaining native `blocked by` edges from `#1088`; those repository issues no
   longer gate a central release.
2. Ask each owning PM to retitle or close its readiness issue according to the independent
   graduation outcome. Do not close or edit unmanaged repositories from this run.
3. Update the readiness contract to reference this ADR and package-scoped use.
4. Close `#1088` after the new decision lands and its native dependency graph is clean.

## Rollback

Supersede this ADR if the organization later needs a coordinated major transition for a
specific dependency family. Already published versions remain immutable; rollback is a
new decision and subsequent release, never unpublishing or restoring deleted versions.
