---
date: 2026-09-21
issue: 1508
impact: patch
title: Reject ref-encoding clobbers in the merge gate
---

The default-branch URI encoding gate now rejects repeated assignments to the
merge workflow's encoded compare ref, and the workflow makes that encoded value
readonly before use. Regression coverage checks direct and guarded clobbers,
rejects duplicate compare functions including Bash's function-keyword and
line-continuation forms, requires the unique production call, and executes the
extracted function against a stubbed API to verify that hostile and slash-bearing
refs remain encoded.
