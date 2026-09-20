---
date: 2026-09-20
issue: 1504
impact: patch
title: Authorize draft and title hold removal
---

The AI review arm now requires a maintain or admin actor before clearing draft and title holds. Title edits enter the trusted lane only when they remove an existing `DO NOT MERGE` marker; edits that keep or add the marker skip runner placement and App-token minting. Existing label-based re-arm and exact-head receipt checks remain in force.
