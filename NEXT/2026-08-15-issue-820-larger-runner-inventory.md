---
date: 2026-08-15
issue: 820
impact: patch
title: Reconcile GitHub-hosted larger-runner inventory
---

The scheduled organization runner reconciler now rejects GitHub-hosted larger runners
unless their exact ID/name identities appear in an explicit reviewed allowlist, which is
empty by default, closing the arbitrary-label route around static hosted-selector policy.

The inventory query validates complete pagination and response shape; a 404, malformed
response, duplicate identity, count mismatch, or API failure is undetermined rather than
clean. Renames and stale entries are drift. Durable reporting reuses #820, updates only the
GitHub Actions bot's immutable-ID-owned comment, ignores foreign markers, and redacts
organization-variable contents. Runner-group values are replaced by lane identities and
safe numeric IDs in errors, drift, remediation, and clean output. Decided in ADR 0103.
