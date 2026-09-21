---
date: 2026-09-21
issue: 1505
impact: major
title: Hold AI review freshness when mergeability cannot be verified
---

The freshness gate now treats failed or permanently unknown mergeability reads through its retry helper as indeterminate and holds the PR instead of allowing an unverified state to proceed. Regression coverage exercises both unreadable and persistently unknown responses.
