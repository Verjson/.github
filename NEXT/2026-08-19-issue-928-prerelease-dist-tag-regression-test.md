---
date: 2026-08-19
issue: 928
impact: patch
title: Add regression test for mixed digit/non-digit prerelease dist-tags.latest selection
---

`node-ci.yml`'s secretless pnpm install rewrite picks `dist-tags.latest` from a
locked-version dict without a real semver comparison (safe under
`--frozen-lockfile`, which never reads the tag). Add a test fixture with a
packument spanning `1.2.3` and `1.0.0-beta.1` (a mixed digit/non-digit
prerelease) to prove the selection never raises a `TypeError`, closing the
#917 follow-up gap.
