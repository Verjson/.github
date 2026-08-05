---
date: 2026-08-05
id: 20260805T190000Z
title: Prune the Active Issues list to what is still open
---

`CLAUDE.md`'s Active Issues list loads into every session, so a closed entry
costs context in each one and misreports the state of the work. Four were stale:
#340 and #393 closed by #409, #350 and #377 closed earlier.

Three open findings from today's adversarial reviews are added in their place —
#411 (`dispatch-merge` ignores `runner_labels`), #412 (`changelog-validate.yml`
accepts a mutable `contract_ref` and executes Python from it, in a workflow ~90
repositories call), and #399, which was already filed.

#405 is deliberately **not** listed: it is closed, and the residue it leaves —
consumer callers generated before it still pass a literal `runner_labels` — is a
consumer-side regeneration, not work this repository owes.
