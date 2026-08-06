---
date: 2026-08-06
issue: 468
title: Record that marking a draft ready fires no gate run
---

Marking a draft PR ready fires no `ai-review-merge` run, so the PR keeps the three
`SKIPPED` gate checks from its last draft-era push until a new commit arrives. Recorded
in the repo notes alongside a corrected description of #263, which is the unrelated
red-`privileged_merge`-on-drafts defect rather than a wedged-gate one.
