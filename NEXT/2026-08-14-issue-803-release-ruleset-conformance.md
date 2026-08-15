---
date: 2026-08-14
issue: 803
title: Require release authorization on every ~DEFAULT_BRANCH ruleset
---

Add a fail-closed scheduled and local conformance audit that requires the release
authorization App on every organization ruleset targeting `~DEFAULT_BRANCH`.

The GET-only audit enumerates every paginated ruleset detail, validates the
response schema without logging sensitive values, binds production to the
event-SHA policy, preserves unrelated actors, rules, and conditions, and records
the exact-token scope and residual read credential in the controlling release
ADR. It coordinates with #731 without creating a new dependency or issue.
