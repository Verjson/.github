---
date: 2026-07-30
id: 20260730T215121Z
title: Isolate Actions write permission in the trusted dispatcher
---

The PR checkout/review gate is back to `actions: read`. A minimal metadata-only job now
holds `actions: write`, validates repository/PR/head/run shapes plus the fixed trusted
workflow identity, and dispatches the existing exact-run privileged continuation
([#235](https://github.com/Verjson/.github/issues/235), ADR 0037).
