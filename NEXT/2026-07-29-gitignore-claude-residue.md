# Ignore Claude Code tooling residue — 2026-07-29

`.gitignore` carried only `.tokensave/`, so every agent scratch worktree under
`.claude/worktrees/`, plus `.claude/settings.local.json` and
`.claude/.headroom_wrap_marker.json`, showed up as untracked noise in `git status`
and could be swept into a `git add -A` by accident.

Ignored explicitly rather than blanket-ignoring `.claude/`, so shared agent or
skill config can still be committed if this repo ever wants it.
