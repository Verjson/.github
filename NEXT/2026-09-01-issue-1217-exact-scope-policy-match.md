---
date: 2026-09-01
issue: 1217
impact: patch
title: node-ci secretless dependency acquisition requires exact scope match against trusted repository policy
---

`.github/workflows/node-ci.yml`'s policy-checked branch of the secretless
dependency validator accepted a caller `approved-internal-scopes` set that was
merely a **subset** of the protected `CI_SECRETLESS_PACKAGE_POLICY` scopes.
Internal-vs-public routing (`path_is_internal` in the lock-scan loop, and the
matching `found`-set filter) is computed from that same caller-supplied
`scopes` value, not from the validated policy scopes. A caller that omitted a
protected scope from its own declaration therefore stopped routing packages
under that scope through the internal-package checks entirely — such a
package would resolve from the public registry unrouted and unchecked, a
dependency-confusion shape. It was inert today because every consumer policy
declares exactly one scope, so subset and equality coincide; it becomes
reachable the moment a policy protects more than one scope.

The scope check now requires an exact match against the trusted policy's
scopes (`scopes != policy_scopes`), while the package list remains a subset
check (`approved.issubset(policy_packages)`, the point of #1150) so a caller
may still narrow which *packages* it uses without narrowing which *scopes*
the trusted policy protects.

Regenerated `.github/workflows/node-ci-protected.yml` from the edited source
and re-pinned `LEGACY_SHA256` in
`scripts/ci-gate/node-ci-required-identity.test.py` to match. Added an
adversarial fixture (`scope-omission`) to
`scripts/ci-gate/node-ci-secretless-compatibility.test.sh` that plants a
public-registry package under a protected-but-undeclared scope and asserts
the validator now fails closed instead of silently ignoring it.

Found by adversarial review of `Verjson/verjson-authn#256`.
