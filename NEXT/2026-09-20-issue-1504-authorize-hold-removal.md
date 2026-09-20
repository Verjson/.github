---
date: 2026-09-20
issue: 1504
impact: patch
title: Authorize all hold removal
---

The AI review arm now requires a maintain or admin actor, based on GitHub's `role_name`, before clearing draft, title, or recognized label holds, and before adding `ai-review` or `re-review` labels can reach App-token minting. Title edits enter the trusted lane only when they remove an existing `DO NOT MERGE` marker; edits that keep or add the marker skip runner placement and App-token minting. Unrelated label additions and removals are filtered on a permissionless untrusted runner before protected jobs start. Recognized hold-label additions still reach the protected arm to disable native auto-merge. All re-arm paths retain exact-head receipt checks.
