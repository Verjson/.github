---
date: 2026-08-01
issue: 281
title: Sync the Active Issues pointer list with what the 2026-08-01 batch left open
---

`CLAUDE.md`'s Active Issues list loads into every session, so a stale entry costs context in
each one and misreports the state of the work. After #270, #271, #273, #275 and #278 closed,
three open findings from the same batch were missing from it and one entry understated its
defect:

- **#263** is not "draft PRs get a red check". The draft-time gate skip is **terminal**: the
  `skipped` check runs stay pinned to that head SHA, marking the PR ready does not re-run the
  `pull_request` gate, and the privileged merge then burns its full ~40-minute wait holding
  `ORG_ADMIN_TOKEN`. Every PR in this batch hit it.
- **#276** (cross-org gate self-deadlock) and **#279** (forgeable attestation provenance) were
  filed during the #277 review and deferred deliberately; neither was listed.

#281 itself — ADR 0028 decision 6 lapsed with no superseding decision — was already added when
it was filed.
