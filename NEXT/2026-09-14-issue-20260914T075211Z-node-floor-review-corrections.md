---
date: 2026-09-14
id: 20260914T075211Z
impact: patch
refs: 1274
title: Correct the Node-floor preparation digest, rule guard and contract pin
---

`scripts/node-floor-ruleset.py` now derives `baselineDigest` from the validated reviewed
baseline instead of the caller's observation. Because `render` tolerates extra top-level
keys the live API returns, the same live ruleset previously produced one digest through
`dry-run` and a different one through `render` while `ruleset` and `baselineProducerAppId`
were identical, so a field named for the reviewed baseline reported provenance of the read
that `baselineSource` already carries. Two proposals of the same policy now compare equal
by digest, and tests hold the two paths to one value.

`producer_app` also asserts the sole baseline rule is a `required_status_checks` rule
rather than only counting rules, matching the error it already raised and making the
helper safe to call outside `render`'s full-baseline equality check.

`scripts/node_floor_ruleset_test.py` pins `.github/required-check-contract.json`'s
`core-checks-node` lane — contexts, selecting properties, ruleset id and name — to
`config/node-floor-baseline.json` itself, so a coordinated edit of the reviewed baseline
and the script's context constant can no longer leave the declared contract silently
diverged. No contract semantics, baseline content or enforcement state changes; this adds
an assertion. See ADR 0176.
