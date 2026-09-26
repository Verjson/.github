---
date: 2026-09-26
issue: 1470
impact: patch
title: Spend the base ref as one percent-encoded path segment at every rules/branches/ reader
---
`scripts/assert-mergeable-head.sh` (Gate A) and `scripts/ci-gate/verify-arm-receipt.sh` now encode the base ref with `@uri` before spending it in `repos/<repo>/rules/branches/<ref>`, matching the four readers that already used the path form. A live probe in the sanctioned scratch repository showed `rules/branches/` resolves the same ruleset for `release%2F2026.09` and `release/2026.09`, so the path form is the strictly safer spelling; Gate A's verdict is unchanged for every current base ref because no Verjson ruleset targets a slash-bearing ref. The URI-encoding enumeration test drops its "deliberate and unresolved" allowlist entries, so the scan now pins the form at both sites.
