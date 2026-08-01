---
date: 2026-08-01
issue: 289
title: Track the unenforced changelog contract in the Active Issues pointer list
---

`CLAUDE.md`'s Active Issues list is the triage pointer loaded into every session, so a
finding that is missing from it is a finding the next session will not see. #289 — this
repository owns the canonical changelog contract but never runs
`python3 scripts/changelog.py validate` over its own `NEXT/`, and one fragment from
e18650b already fails it — was filed while adding the #244 fragment and is now listed.
