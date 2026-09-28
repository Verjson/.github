---
date: 2026-09-28
issue: 1646
impact: patch
title: Warm the pinned changelog engine for protected CI scripts
---

Protected Node CI now verifies and mounts the pinned changelog engine read-only before running its exact offline script plan, so release-contract checks can run without network access.

The protected workflow reads the renderer's `CONTRACT_REF` and `CONTRACT_SHA256` declarations as data, fetches the canonical engine at that immutable ref, and checks the digest before making the cache available. The existing networkless sandbox and `test:release` plan remain enabled. See [ADR 0209](../docs/decisions/0209-hosted-tool-cache-trust-is-a-tree-property/README.md) and [#1646](https://github.com/Verjson/.github/issues/1646).
