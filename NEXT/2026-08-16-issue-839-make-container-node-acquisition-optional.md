---
date: 2026-08-16
issue: 839
impact: patch
title: Keep container Node acquisition optional
---

Allow non-Node container adopters to build without a lockfile, npm installation, transfer cache, pre-existing base configuration, or `node_modules` build context.

Private-package adopters retain the reviewed-base allowlist and the complete credential-isolation and exact-cache handoff contract recorded in ADR 0078.
