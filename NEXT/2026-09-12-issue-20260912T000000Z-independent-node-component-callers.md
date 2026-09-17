---
date: 2026-09-12
id: 20260912T000000Z
impact: minor
title: Generate independent Node component release callers
---

The canonical changelog caller generator now emits an independent component release caller while preserving the root caller's `v`, unscoped, and root package defaults. Component publication requires the adopter's package preparation hook to run successfully in the tagged publish job before script-disabled packing, preventing verification-only nested distributions from being published.

This records the release contract required by [Verjson/verjson-cli#245](https://github.com/Verjson/verjson-cli/pull/245) and [ADR 0176](../docs/decisions/0176-independent-node-component-callers/README.md).
