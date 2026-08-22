---
date: 2026-08-22
issue: 983
impact: minor
title: Fail a PR whose ADR number already exists on main or another open PR
---

`docs/decisions/NNNN-<slug>/` numbers are picked by each PR author as "the
next free number as seen from main" -- two PRs open at once cannot see each
other's allocation and can pick the same number silently, as three
concurrent PRs did live for `0004` in `Verjson/verjson-ai-gguf`.
`scripts/gen-adr-index.sh` only ever sees one PR's own tree, so it faithfully
regenerates an index containing the duplicate, and git merges the two
differently-named directories without a conflict.

A new `scripts/ci-gate/adr-number-collision.py`, wired into `actions-ci.yml`
as a pull-request-only job feeding the required `shell-tests` check, reads
live GitHub state -- this PR's newly added ADR directories, the directories
already on `main`, and the newly added directories of every other currently
open pull request -- and fails the PR the moment a number collides with a
different path in either set. This is option 1 from the issue: it converts
a silent `main`-landing defect into a failed check without changing the
numbering convention itself; options 2 and 3 (numbering at merge time,
dropping the number from the directory name) are deliberately deferred.
