---
date: 2026-07-29
id: 20260729T143257Z
title: Ignore Claude Code tooling residue
---

`.gitignore` carried only `.tokensave/`, so every agent scratch worktree under
`.claude/worktrees/`, plus `.claude/settings.local.json` and
`.claude/.headroom_wrap_marker.json`, showed up as untracked noise in `git status`
and could be swept into a `git add -A` by accident.

Ignored explicitly rather than blanket-ignoring `.claude/`, so shared agent or
skill config can still be committed if this repo ever wants it.
