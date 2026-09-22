---
date: 2026-09-22
issue: 1548
impact: patch
title: Review fastlane selectors for reusable CI callers
---

Allow the exact `CI_RUNNER_FASTLANE` lane expression only for same-contract `node-ci.yml` calls that bind pull requests to secretless execution and expose exactly pull requests plus pushes to `main`. Regressions reject unguarded forks, merge queues, dispatches, non-default pushes, mismatched pins, and unreviewed variants so private compatibility checks retain their hosted sandbox without routing PR-derived code there.
