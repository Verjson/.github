---
date: 2026-08-15
issue: 815
impact: patch
title: Enforce metered runner routing in reusable actionlint
---

Reusable actionlint now rejects literal macOS and Windows hosted selectors in every Verjson caller while leaving foreign callers and the separately deferred Linux policy unchanged.

The organization-owned checker and its checksum-pinned YAML dependency run from the reusable workflow's immutable revision, so a consumer pull request cannot weaken the policy it is being checked against. See ADR 0103.
