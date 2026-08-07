---
date: 2026-08-07
issue: 326
title: Fail when the privileged merge continuation is missing
impact: patch
---

The merge dispatcher now fails with actionable generator and secret-access
remediation when a repository lacks its trusted privileged continuation.
A scheduled read-only conformance audit reports missing callers or
`ORG_ADMIN_TOKEN` access across active Verjson repositories before merge
delivery is needed.
