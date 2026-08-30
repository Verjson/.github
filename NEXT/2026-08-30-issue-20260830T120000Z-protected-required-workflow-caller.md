---
date: 2026-08-30
id: 20260830T120000Z
title: Adopt authenticated protected Node required workflow
impact: patch
---

- Resolve empty-context required-workflow deliveries through the authenticated current Actions run and exactly one live pull request.
- Call the immutable protected Node contract with explicit admitted identity outputs and least-privilege API scopes.
- Bind every candidate checkout to the admitted immutable head SHA and fail closed on stale, ambiguous, malformed, or partial evidence.
