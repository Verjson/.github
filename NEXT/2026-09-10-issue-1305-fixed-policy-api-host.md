---
date: 2026-09-10
issue: 1305
impact: patch
title: Bind Node-floor policy reads to GitHub.com
---

Explicitly select GitHub.com for fixed read-only policy requests so ambient GH_HOST cannot redirect the target. Preserve normal environment handling and GET-only behavior; regress conflicting host settings.
