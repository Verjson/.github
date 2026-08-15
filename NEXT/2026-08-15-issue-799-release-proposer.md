---
date: 2026-08-15
issue: 799
impact: minor
title: Generate explicit, idempotent release proposals
---

The canonical changelog generator now emits an adopter release proposer that either maintains one released-preview issue or dispatches the existing guarded `Release` workflow with the exact derived version, with autonomy fixed in source and least-privileged permissions.

The reusable workflow gates on selected `NEXT/` fragments at the default-branch head, derives and previews them through one immutable contract pin, serializes concurrent decisions, and never consumes fragments, commits, tags, or pushes. Proposal and dispatch API effects are idempotent across pagination and fail closed on ambiguity or missing acknowledgement. ADR 0101 records the authority boundary.
