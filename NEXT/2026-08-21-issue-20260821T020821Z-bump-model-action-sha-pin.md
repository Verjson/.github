---
date: 2026-08-21
id: 20260821T020821Z
impact: patch
title: Bump the audited claude-code-action pin alongside its Renovate digest bump
---

Renovate's `renovate/github-actions-digests` PR bumped
`anthropics/claude-code-action` to `3f854a8fb5146b39d5cbf8b57f70d80810e1366f`
in `ai-review-merge.yml` without updating the mirrored `MODEL_ACTION_SHA`
constant in `scripts/ci-gate/event-driven-authorization.test.py`, per the
ADR 0083 contract that requires both to match. Audited the upstream diff
(`e2a4b761c...3f854a8`): a Claude Code CLI version bump and a
credential-leak hardening fix in `git-config.ts` (clears the checkout auth
header from `actions/checkout` v6+'s `include.path`-based config layout, not
just the legacy repo-local config) — no change to actor/login normalization,
so the ADR 0083 authorization contract is unaffected. Updated the test
constant to match.
