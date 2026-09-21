---
date: 2026-09-21
issue: 1508
impact: patch
title: Reject ref-encoding clobbers in the merge gate
---

The default-branch URI encoding gate now rejects repeated assignments to the
merge workflow's encoded compare ref, and the workflow makes that encoded value
readonly before use. This closes direct and guarded clobber paths that could
otherwise send an unencoded branch ref to the compare API.
