---
date: 2026-09-11
id: 20260911T210500Z
impact: patch
title: Ignore remaining Claude Code tooling residue files
---

Two residue files the scoped Claude Code ignore block missed —
`.claude/.headroom_wrap_owners.json` and `.claude/scheduled_tasks.lock` — kept
`git status` reporting an untracked `.claude/`, a standing false signal competing
with real uncommitted work. Add them to the existing scoped block.
