---
date: 2026-08-17
issue: 878
impact: patch
title: Report actionable npm acquisition failures
---

Preserve the npm exit status and bounded, token-redacted stderr when private-package acquisition fails, and identify authorization, permissions, network, registry, and integrity as distinct possible causes.
