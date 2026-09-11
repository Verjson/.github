---
date: 2026-09-11
id: 20260911T223000Z
refs: 1285
impact: minor
title: Pin the gate-rearm policy call for required-workflow execution
---

An isolated canary proved a ruleset required workflow cannot resolve a relative
reusable call: revision b050 startup-failed on both selectors while the identical
content ran locally, so the shared rule stays frozen on c597. Replace gate-rearm's
relative app-key-environment call with an absolutely pinned reference and record
the corrected invocation semantics, including main-only environment admission for
develop-targeted pull_request_target runs, in ADR 0171.
