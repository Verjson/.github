---
date: 2026-09-09
issue: 1275
impact: patch
title: Skip body-only review re-arm events before allocating credentials
---

The canonical AI review arm skips body/base-only PR edits before scheduling its trusted runner or minting an App token. Title edits and other lifecycle events retain the existing hold cancellation, source binding, and review authorization checks.
