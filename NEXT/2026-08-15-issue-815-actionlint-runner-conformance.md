---
date: 2026-08-15
issue: 815
impact: patch
title: Enforce metered runner routing in reusable actionlint
---

Reusable actionlint now rejects literal macOS and Windows hosted selectors in every Verjson caller while leaving foreign callers and the separately deferred Linux policy unchanged.

The organization-owned checker retains fail-closed expression validation, and its checksum-pinned YAML dependency is extracted into a new secure runner-temporary directory outside the caller checkout, with the runner temp root bound explicitly for static validation. A consumer pull request cannot weaken or prepopulate the policy it is being checked against. See ADR 0103.
