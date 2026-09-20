---
date: 2026-09-20
issue: 1504
impact: patch
title: Enforce title hold state transitions
---

The AI review arm now requires a maintain or admin actor, based on GitHub's `role_name`, before clearing draft, title, or recognized label holds, and before adding `ai-review` or `re-review` labels can reach App-token minting. Title edits that add a `DO NOT MERGE` marker reach the trusted arm without hold-clear authorization so it can disable native auto-merge; edits that remove the marker require maintainer or admin authorization. Body/base-only edits and title edits that leave held state unchanged skip runner placement and App-token minting. Unrelated label additions and removals are filtered on a permissionless untrusted runner before protected jobs start. Recognized hold-label additions still reach the protected arm to disable native auto-merge. All re-arm paths retain exact-head receipt checks.
