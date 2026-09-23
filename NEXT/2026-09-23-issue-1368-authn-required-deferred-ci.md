---
date: 2026-09-23
issue: 1368
title: Restore deferred CI to the Authn required workflow
impact: patch
---
Regenerate the organization-owned Authn type-surface caller at a current immutable Node CI contract so stability-delay deferrals remain visible instead of appearing as successful no-op runs.

The caller contract now resolves its pinned reusable workflow and rejects pins without ADR 0178's `deferred-ci` job while preserving workflow-level status-read permission.
