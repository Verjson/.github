---
date: 2026-08-02
issue: 318
title: Close the migration-checklist gaps that let adopters keep a second publisher
---

`docs/changelog/migration.md` now says to delete `.releaserc.json` when adopting
the reusable release workflow, and to generate all three consumer files rather
than hand-writing them. Both omissions produced real defects: two repositories
finished migration with a semantic-release config still tracked, and six
hand-wrote a contract test that asserted a pre-release tree.

It also states that a branch cut before migration needs `origin/main` merged in
before its fragments are normalized, so the pre-contract release path surfaces
as a conflict instead of being silently reinstated.
