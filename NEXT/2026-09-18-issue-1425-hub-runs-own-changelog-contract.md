---
date: 2026-09-18
issue: 1425
impact: patch
title: Run the published changelog contract on the hub's own pull requests
---

`Verjson/.github` now validates its own `NEXT/` fragments against the contract it
publishes, from `scripts/ci-gate/hub-changelog-validate.sh` in the `platform`
actions-ci group. A fragment the pull request adds without `impact:` now reddens
the hub's own checks. Only `validate --base` evaluates that field, and nothing on
the hub was passing it a base; a duplicate fragment identity was already caught,
by the base-less `validate` the `changelog-release` group has always run.

The hub carries `verjson-stack=actions` and `verjson-core-checks=enforced`, so it
sits in the `core-checks-actions` ruleset cohort and not in
`changelog-contract-required`: `changelog / validate` never ran here. #1418 merged
a fragment missing `impact:` for exactly that reason, and the `CHANGELOG/<version>.md`
snapshot it would have been consumed into is immutable. The remedy runs the contract
at its source rather than adopting the hub's own consumer packaging (#1425) — the hub
is the producer, and this keeps working if the cohort properties are reorganized.
