---
date: 2026-09-21
issue: 1393
impact: patch
title: Keep queued AI review runs eligible for receipt validation
---

Receipt-bound AI review recovery now accepts a live workflow-dispatch run that is still queued while an environment-gated sibling waits for admission; it continues to require the exact run identity and rejects terminal or unrelated runs ([#1393](https://github.com/Verjson/.github/issues/1393)).

Completion now selects the Checks API token from the verified check owner: the GitHub Actions token for Actions-owned checks and the scoped authorization App token for App-owned checks. The App token requests only `checks:write` in addition to its existing read/write permissions, so a terminal check cannot remain pending behind an owner mismatch.
