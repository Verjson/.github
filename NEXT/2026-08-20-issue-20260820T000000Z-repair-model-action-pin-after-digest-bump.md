---
date: 2026-08-20
id: 20260820T000000Z
impact: patch
title: Repair the audited Claude review action pin after a Renovate digest bump
---

Renovate proposed bumping `anthropics/claude-code-action` to
`e2a4b761cd77a1138a5b41410eda9b28581f9bcd`, but ADR 0083 requires the merge
gate's separately audited `MODEL_ACTION_SHA` constant to be updated in the same
PR after reviewing the upstream diff. The upstream range (5 commits) does not
touch `src/github/validation/actor.ts` or `src/github/validation/trigger.ts` —
the authorization normalization ADR 0083 pins — so the source audit passes and
`event-driven-authorization.test.py` is updated to match.
