---
date: 2026-08-12
id: 20260812T131211Z
title: Ignore the .worktrees/ agent scratch directory
---

`.gitignore` now covers `.worktrees/` alongside the `.claude/worktrees/` entry it
has carried since the tooling-residue block was added, so a clean checkout
reports a clean `git status` again.

Only the Claude Code path was ignored. Codex and plain `git worktree` runs write
their per-task checkouts to `.worktrees/` instead, and those are removed at
terminal completion — but the directory itself survived every sweep, so
`git status` reported `?? .worktrees/` permanently. A standing untracked entry is
worse than untidy: it competes with the real uncommitted-work signal, which is
the one thing `git status` exists to show. Found while cleaning up three merged
worktrees at the end of the 2026-08-12 session.
