---
date: 2026-08-06
issue: 458
title: 'fix(actions): gate exit status reflects the merge, not branch cleanup'
---

The privileged merge step no longer passes `--delete-branch` to `gh pr merge`.
The head ref is deleted afterwards, as a separate call that cannot fail the
step.

On a repository with auto-delete-branch-on-merge, GitHub removes the head ref
during the merge, so `--delete-branch` raced it and lost with a 404 — reporting
a red gate on a pull request that had merged correctly. On this repository's own
merge path the same 404 was misread as a concurrent run's merge and exited
early, skipping the follow-up issues the gate is supposed to file.

The ref name comes from `headRefName`, added to a projection the step already
fetched, so cleanup costs no extra API call.

Cleanup is skipped outright for a pull request from a fork. That branch name
belongs to the fork, not to the repository being merged into, so deleting it by
name in the base repository would have removed whichever same-named branch the
base repository happened to own.
