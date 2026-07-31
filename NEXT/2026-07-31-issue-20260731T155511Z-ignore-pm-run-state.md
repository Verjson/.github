---
date: 2026-07-31
id: 20260731T155511Z
title: Ignore PM orchestrator run state and track the draft-PR gate defect
---

The PM orchestrator writes a `.pm-execution-plan-*.md` and `.pm-run-brief-*.json` per
session and is meant to delete both at terminal completion. When a session ends without
that step the files linger as untracked residue, so `.gitignore` now covers `.pm-*`
alongside the existing Claude Code tooling entries.

A stale PM session handoff had also been left in `NEXT/`, where `render-next.sh` picked
it up as a legacy fragment and rendered eighty lines of internal session narrative into
the changelog. `NEXT/` holds released-change fragments only; the handoff's open items
were already tracked as issues, so it is removed rather than relocated. The Active
Issues pointer list additionally gained
[#263](https://github.com/Verjson/.github/issues/263), a live gate defect that was filed
but never listed.
