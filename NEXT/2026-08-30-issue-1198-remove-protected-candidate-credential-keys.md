---
date: 2026-08-30
issue: 1198
title: Remove credential keys from protected candidate execution
---

- Remove GitHub, npm, cloud-provider, and Actions OIDC credential keys from every protected Node candidate execution route instead of exposing empty values.
- Preserve immediate authenticated live-PR revalidation and the byte-identical legacy Node workflow.
- Reject non-empty protected `schema-dir` inputs and omit the unsupported credentialed schema install route.
