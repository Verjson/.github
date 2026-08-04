---
date: 2026-08-04
issue: 350
title: Remove branch-selectable privileged watchdog dispatch
---

Remove `workflow_dispatch` from the privileged fleet watchdog because a selected
branch controls the workflow definition as well as checkout defaults. Scheduled
runs now bind checkout to their immutable default-branch `github.sha`; a wired
contract test locks the trigger, checkout, named-step, command, and token-ordering
boundaries. ADR 0049 records the fix and the residual #261/#265 secret-scope work.
