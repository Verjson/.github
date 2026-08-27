# 0149 — Authorize exact secretless call subsets

- **Date:** 2026-08-27
- **Issue:** [Verjson/.github#1149](https://github.com/Verjson/.github/issues/1149)
- **Supersedes:** The per-call policy-equality requirement in [ADR 0140](../0140-resolve-package-compatibility-without-consumer-credentials/README.md)
- **Category:** package credentials / protected authorization policy — **sensitive class**
- **Status:** Accepted

## Context

ADR 0140 made the protected `CI_SECRETLESS_PACKAGE_POLICY` repository variable the
authority for package scopes, exact package identities, and compatibility ranges. It
required every reusable `node-ci` call to repeat the complete protected scope and package
sets. The lock validator independently rejects a caller-approved package that is absent
from that call's lock, except for the one explicitly authorized compatibility target.

A repository can legitimately have more than one reusable call over different dependency
graphs. [Verjson/verjson-authn#251](https://github.com/Verjson/verjson-authn/pull/251)
exposed the contradiction during the v1 readiness wave tracked by
[Verjson/.github#1088](https://github.com/Verjson/.github/issues/1088). Its general call
locks `@verjson/identity-contracts` and `@verjson/tsconfig`; its type-surface call also
authorizes the absent `@verjson/authn` compatibility target. Repeating the repository-wide
three-package policy in the general call fails the unused-approval guard. Narrowing that
call to its exact graph fails ADR 0140's equality guard. A self-dependency, a package
credential in consumer execution, or a wider runtime graph would weaken the evidence the
boundary is intended to provide.

## Decision

Treat `CI_SECRETLESS_PACKAGE_POLICY` as the protected repository-wide authorization
superset. Each reusable call continues to declare exact `approved-internal-scopes` and
`approved-internal-packages` sets. When the protected policy is present, both caller sets
must be subsets of their protected counterparts. Every protected scope and package is
validated with the same exact lowercase npm identity grammar before the subset comparison,
including protected entries that the current call does not use.

Decode both the per-call compatibility request and protected policy with duplicate-object-
key rejection at every nesting level. JSON's usual last-value-wins behavior must not choose
between two authorization-bearing values. Existing array uniqueness checks remain separate
and mandatory for scope, package, compatibility-range, and requested-range lists.

Validate the protected compatibility map against the repository-wide protected package
set, not the current call's smaller set. A compatibility request still must name one exact
package approved by that call, and every requested range must remain a subset of that
package's protected ranges. Thus protected authority may cover several calls without
letting any call select an unprotected package, scope, or range.

Keep lock-derived exactness independent from protected authorization. Every internal
package found in one call's lock must be approved by that call, and every caller-approved
package must be found in that lock unless it is the call's one authorized compatibility
target. Protected policy membership alone never excuses an unused approval. The existing
same-repository event boundary, non-executing authenticated acquisition, bounded transfer,
credential scrub, registry identity checks, and consumer execution isolation are unchanged.

The behavioral contract uses the exact authn two-call policy shape. Its mutations restore
the former equality check, disable the subset guard, and disable the unused-approval guard.
They prove respectively that equality recreates the contradiction, that missing subset
validation admits package and scope expansion, and that protected membership must not
weaken per-call lock exactness. A fourth mutation restores permissive JSON decoding and
proves duplicate keys would otherwise be accepted in the request, protected policy, and
nested compatibility map.

## Consequences

- One protected repository policy can authorize multiple exact, smaller reusable-call
  dependency graphs.
- A caller cannot expand package, scope, or compatibility-range authority beyond the
  protected repository variable.
- Adding a package to the protected policy does not silently add it to any call's acquired
  or executed dependency graph.
- Existing callers whose approved sets equal the protected policy remain valid.
- Default `@verjson` callers without a protected policy retain their existing behavior;
  compatibility mode still requires a non-empty protected policy.

## Rollback

Reverting the subset relation to equality restores the authn two-call contradiction and is
not an acceptable security rollback. A caller can temporarily split its protected policy
across separate repositories, but must not introduce self-dependencies or expose package
credentials to consumer-controlled execution.
