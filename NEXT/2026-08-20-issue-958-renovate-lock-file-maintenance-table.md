---
date: 2026-08-20
issue: 958
impact: patch
title: Attribute Renovate lock file maintenance pull requests
---

`scripts/renovate-changelog.py` now recognizes Renovate's `lockFileMaintenance` table
shape and writes a fixed `NEXT/` fragment for it, so the weekly lock-file-maintenance pull
request no longer needs a hand-written entry.

`parse_updates` admitted a table only when its header row carried both `Package` and
`Change`. A lock-file-maintenance body carries a two-column `| Update | Change |` table
with a single `lockFileMaintenance` row and no `Package` column at all, so zero tables were
recognized and the "exactly one Renovate update table" guard failed closed on every such
pull request — the attribution job went red beside the already-red `changelog / validate`,
and the fragment still had to be written by hand (`Verjson/AiB#231` and two earlier weeks).
The parser stays strict for the `Package`/`Change` shape: this is an additional recognized
shape, requiring exactly the `Update`/`Change` headers, exactly one row, the literal
`lockFileMaintenance` update type, and a plain-text change cell. A body carrying that table
plus any other update table still fails the "exactly one" guard rather than guessing. Since
the change refreshes every transitive lock entry rather than named dependencies, the
generated fragment carries no per-package rows and lands at
`NEXT/<date>-issue-<pr>-renovate-lock-file-maintenance.md`. See
[#958](https://github.com/Verjson/.github/issues/958).
