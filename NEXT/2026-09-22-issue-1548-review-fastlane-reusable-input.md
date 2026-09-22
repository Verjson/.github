---
date: 2026-09-22
issue: 1548
impact: patch
title: Review fastlane selectors for reusable CI callers
---

Allow the exact `CI_RUNNER_FASTLANE` lane expression in reusable workflow runner inputs, with a regression fixture that rejects unreviewed variants. This lets private compatibility checks retain their hosted sandbox while runner placement stays centrally configurable.
