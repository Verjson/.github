---
date: 2026-08-07
issue: 379
title: Add a verified changelog tooling cache contract
---

Let generated changelog renderers and contract tests use a runner-preloaded,
commit-keyed tool cache after verifying the exact pinned digest, with immutable
raw GitHub download as a repair fallback.

ADR 0065 defines the stable preload path and fail-closed restricted-egress
behavior without requiring adopter repositories to vendor or hand-edit tooling.
