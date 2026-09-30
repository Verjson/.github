---
date: 2026-09-30
issue: 1663
impact: patch
title: Separate AI review re-arm events
---
The generated AI review label caller now runs only for `labeled`; lifecycle events remain on the gate re-arm caller, avoiding a duplicate privileged re-arm job. See [Verjson/.github#1663](https://github.com/Verjson/.github/issues/1663).
