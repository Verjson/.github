---
date: 2026-08-02
id: 20260802T031500Z
title: Sync the Active Issues pointer list with what the 2026-08-02 batch left open
---

The Active Issues list loads into every session, so a stale entry costs context in each one
and misreports the state of the work. After #251, #276 and #293 closed in this batch, and
#289 earlier, four entries described work that is done.

Two entries also needed rewording rather than removal:

- **#279** is no longer "forgeable by any run that merely references the gate". ADR 0044
  closed that, and closed the repo-local forgery in the required-workflow shape — every
  Verjson repository. What remains is confined to the reusable-caller shape, which no
  repository uses today. The entry says which half is open so the next session does not
  re-solve the closed half.
- **#261** now carries why it matters: it is the durable closure for #279's residual, not a
  free-standing hardening task.

Added #300 (the `v2.1.1` release ADR 0014 promised and never cut, so the documented exact
pin lacks the #164 eligibility fix) and #303 (`ai-review-merge.yml` has no
`workflow_files_changed` guard on its own direct merge path, while ADR 0044 now depends on
that guard being load-bearing).
