---
date: 2026-08-12
issue: 757
title: Bind ruleset-created arm receipts to organization provenance
---

Accept authorization-arm receipts from organization-required workflow runs even
when a consumer has no repository-local caller, while binding those runs to the
canonical Verjson source repository and `refs/heads/main` organization rule.
Matching-path repository rules, mixed trusted and impostor rules, and wrong-ref
sources remain rejected.

The verifier preserves workflow-ID equality for repository-local callers and
applies ADR 0039's organization-ruleset trust boundary only to exact
consumer-scoped required-workflow URLs. ADR 0094 records the live ID mismatch and
the retained ambient-configuration limitation.
