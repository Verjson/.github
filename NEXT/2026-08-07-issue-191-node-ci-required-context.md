---
date: 2026-08-07
issue: 191
title: Keep the required Node CI context satisfied during Renovate deferrals
impact: patch
---

The reusable Node workflow now reports a successful `ci / build-test` no-op
when Renovate's release-age gate intentionally defers the suite. All checkout,
install, build, test, database, and cache steps remain suppressed until the
hold clears, while eligibility errors continue to fail open by running CI.
