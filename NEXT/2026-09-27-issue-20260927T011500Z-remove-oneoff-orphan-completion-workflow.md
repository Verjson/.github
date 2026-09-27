---
date: 2026-09-27
id: 20260927T011500Z
impact: patch
title: Remove the one-off orphaned-check completion workflow after its single run (#1540)
---
`oneoff-1540-complete-orphaned-checks.yml` ran once on `main` (run recorded on #1540) and terminalized the three `AI review authorization` check-runs App 4528902 left `in_progress` since 2026-09-22; all three now read back `completed/cancelled`, and a paginated org-wide query over every open pull request finds no in-progress or queued check-run from that App. The workflow is deleted so it cannot become a standing check-run writer.
