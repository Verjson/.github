---
date: 2026-08-07
issue: 323
title: Review publication pull requests over 300 files
---

Build the AI gate's review diff locally from the immutable checked-out PR head
and a freshly fetched base ref, removing GitHub's 300-file whole-diff endpoint
limit. Base-history fetches retain bounded retry and masked diagnostics; missing
merge history or local diff failure remains typed and fail-closed.

The contract test exercises a 301-file diff, transient and exhausted fetch
failures, missing merge-base behavior, and removal of `gh pr diff` from the
review path.
