---
date: 2026-09-14
issue: 1274
impact: minor
title: Declare the conditional Node-floor required-check lane
---

`.github/required-check-contract.json` now declares `core-checks-node-floor` — selected
by `verjson-stack=node`, `verjson-core-checks=enforced` and the new
`verjson-node-floor=node22` property, requiring only `ci-node22 / build-test` and
`ci-node22 / eligibility` — so an organization lane that only some repositories carry is
readable where every other lane is declared, instead of living inside one preparation
script. `stacks.node.contexts` is untouched and the property defaults to `disabled`, so
no Node repository acquires a floor requirement and no repository-level validation
changes; the declared entry is inert for the audit and rollout paths, which consume the
plan by the single declared rollout name.

`scripts/node-floor-ruleset.py` now derives the floor contexts' producer App from the
reviewed `core-checks-node` baseline rather than a hard-coded `15368`, and fails closed
when that baseline omits a binding, carries a non-positive or non-integer one, binds its
contexts to differing Apps, or drifts in context names. The rendered candidate publishes
the derived `baselineProducerAppId`, and tests hold the declared contract entry and the
prepared payload equal. Preparation is still read-only, still emits a disabled candidate,
and ADR 0172's live acceptance gates remain unsatisfied. See ADR 0176.
