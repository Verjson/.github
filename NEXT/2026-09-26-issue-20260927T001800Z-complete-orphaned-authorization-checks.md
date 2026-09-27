---
date: 2026-09-26
id: 20260927T001800Z
impact: patch
title: One-off workflow terminalizes three orphaned authorization check-runs (#1540)
---
`oneoff-1540-complete-orphaned-checks.yml` is a dispatch-only operator workflow, bound to the main-only `ai-review-app` environment, that completes the three `AI review authorization` check-runs App 4528902 left `in_progress` on 2026-09-22 after their pull requests reached a terminal state (verjson-git-runners 106611362849, verjson-authn 106657731199, verjson-agents 106661948598). It refuses any check-run that is not exactly one of those three, still in progress, owned by that App, and at the recorded head; it writes `completed/cancelled` with an explanatory summary and reads the result back. The workflow is deleted in the follow-up once all three read back terminal.
