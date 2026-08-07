---
date: 2026-08-07
issue: 411
title: Honor explicit consumer runner labels on merge dispatch
---

Apply a reusable caller’s explicit `runner_labels` fleet selection consistently to `preflight`, `gate`, and the metadata-only `dispatch-merge` job, while preserving every absent-input visibility and lane fallback.

ADR 0068 records the scoped-token security boundary and the caller-authority decision. The semantic routing coverage stacks on #357, and the branch follows #346’s completion of the fast-lane backlog.
