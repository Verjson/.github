---
date: 2026-09-14
issue: 1285
title: Declare broad App key copies withdrawn so the nightly scope audit tracks the real exposure
impact: patch
---

`config/org-actions-secret-policy.json` listed nine of the organization's thirteen
live Actions secrets, so `org-secret-scope-audit` had failed nightly since at least
2026-09-08 on a generic `manifest mismatch`. A stale manifest does not merely
under-report — it turns the organization's only standing credential-scope control
into a check nobody can read, and it hid that `RELEASE_APP_PRIVATE_KEY`,
`RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY`
sit at visibility `all`.

The policy gains `target_visibility: "withdrawn"`, meaning the organization copy must
not exist. An absent withdrawn secret is conformance; a present one fails with a
message naming the surviving broad copy. The five App private keys #1285 tracks are
declared withdrawn, so the audit turns green for each one exactly when its broad copy
is deleted, and is the standing tracker until then. Policy shape is now validated for
every manifested secret rather than only those present live, since a withdrawn entry
is normally absent and would otherwise never be checked at all.

Three pre-existing visibility drifts this surfaces rather than introduces —
`DEEPSEEK_API_KEY`, `OPENAI_API_KEY` and the newly manifested `REWORK_RECONCILE_TOKEN`
are live at `all` against reviewed `selected` grants — remain operator work.
