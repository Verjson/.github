---
date: 2026-08-08
issue: 622
title: Isolate Actions CI matrix groups
---

Runs each Actions CI matrix group from its own job-temporary worktree so
parallel contract tests cannot observe or overwrite another group's fixtures on
a shared self-hosted runner.
