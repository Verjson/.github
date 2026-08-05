---
date: 2026-08-05
issue: 396
title: Assert the semantic-release pin as a property, not as a literal version
---

`node-workflow-pins.test.sh` hardcoded `25.0.8` in three assertions, so every
Renovate bump of `semantic-release` was red by construction. #396 carried a
correct, exact-pin bump — `25.0.8` → `25.0.9`, with `resolved` and a sha512
`integrity` — and failed for saying so:

```
FAIL - semantic-release dependency is not exact
FAIL - semantic-release lockfile entry is missing or mutable
```

Neither message was true of the change. A guard that fails on the routine,
correct update is worse than no guard: it trains reviewers to override it, and
the next override lands the bump that genuinely is a range.

The assertions now pin the invariant they were standing in for — the manifest
names an exact `x.y.z`, and the lockfile names **the same** version with a sha512
integrity and no resolved-without-integrity entries anywhere. That survives a
bump; the literal only asserted that nobody had upgraded yet.

Verified by mutation: a `^25.0.8` range fails, and a manifest bumped ahead of its
lockfile fails. `semantic-release` remains a live dependency of the reusable
`node-release.yml`, so this is not the retired-tooling path — ADR 0038 retires
semantic-release for the changelog contract, and #402 is what replaces this
workflow.
