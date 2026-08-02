---
date: 2026-07-29
id: 20260729T044424Z
title: Target visibility stub gh coverage
---

- `scripts/ci-gate/target-visibility.test.sh` (new): extracts the
  `target_visibility` step's `run:` block from `ai-review-merge.yml` and drives
  it with a stub `gh` — a public target publishes `target_private=false`, a
  private one `true`, and a failed lookup exits 0 while publishing an EMPTY
  value plus a `::warning::`, so the gate job stays on the self-hosted `gate`
  pool. Also pins the consuming contract: `runs-on` routes the isolated pool
  only on the exact string `'false'`, so an unresolved visibility can never fail
  open. Wired into `actions-ci.yml`. (#170)
- `scripts/ci-gate/dispatch-target-guard.test.sh`: cover the tightened
  `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` charset — legal dot/dash/underscore repo
  names still pass, while backticks, whitespace and newlines in an otherwise
  same-owner target now fail closed, closing the annotation-injection vector the
  previous `^[^/]+/[^/]+$` shape accepted. (#119, #176)
