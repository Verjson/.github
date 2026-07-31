---
date: 2026-07-30
issue: 249
title: Standardize changelog fragments and immutable release snapshots
---

Added the organization contract, schema, reusable validation and release
workflows, migration guide, and reference tooling for collision-resistant
unreleased fragments and immutable released snapshots
([#249](https://github.com/Verjson/.github/issues/249), ADR 0038).
Reusable validation and release jobs follow the organization-aware runner
routing contract, with caller overrides and an external hosted fallback.
Temporary in-place compatibility gives historical prose stable file identities;
only explicit metadata or configured migration directories infer issue ownership.
Workflow entrypoints consistently use the available `python3` runtime.
