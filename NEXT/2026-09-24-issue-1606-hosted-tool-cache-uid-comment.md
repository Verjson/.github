---
date: 2026-09-24
issue: 1606
impact: patch
title: Document why hosted tool-cache root admits uid 1001
---

`gen-node-ci-protected.py`'s `hosted_tool_cache_uids = (0, 1001)` now carries a
comment naming uid 1001 as the GitHub-hosted "runner" account, addressing the
non-blocking AI-review follow-up from #1603. No behavior change; regenerated
`node-ci-protected.yml` accordingly.
