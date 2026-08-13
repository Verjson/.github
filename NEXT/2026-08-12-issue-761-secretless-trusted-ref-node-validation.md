---
date: 2026-08-12
issue: 761
title: Validate trusted Node refs without consumer credentials
---

Add an opt-in trusted-ref lane to canonical Node CI that reuses the exact private-package cache, immutable auxiliary tree, credential scrub, rebuild allowlist, and ordered audit/smoke plan from secretless PR validation while admitting only pushes and explicit dispatches.

Pull requests and forks remain confined to the existing secretless PR boundary. Trusted pushes cannot be deferred by a stale `renovate/stability-days` status, and ADR 0097 records the event, permission, package-token, and runner split.
