---
date: 2026-09-13
id: 20260913T173500Z
title: Group pydantic and pydantic-core so a concurrent update to both bumps them together
impact: patch
---

`pydantic-core` is `pydantic`'s compiled Rust backend; the two are version-coupled
upstream, and bumping only one risks pairing an unsupported combination.
`verjson-editor#123` bumps `pydantic-core` alone in
`benchmarks/unstructured/requirements.txt` (pinned at `pydantic==2.13.5` /
`pydantic-core==2.46.5`). A new `packageRules` entry groups `pydantic` and
`pydantic-core` across `pip_requirements`, `pep621`, and `poetry`, matching the
existing "github actions digests" group's rationale for coupled dependencies.

This reduces but does not eliminate the risk: a `groupName` only merges updates
Renovate already has *concurrently pending* for both packages into one PR — it does
not manufacture a compensating `pydantic` bump when only `pydantic-core` has a new
release available, which is exactly `#123`'s own shape today (no `pydantic` update is
currently pending). The durable fix is not pinning `pydantic-core` independently at
all, since `pydantic`'s own dependency spec already determines a compatible version;
that is a per-repository `requirements.txt` change, tracked separately rather than
folded into this org-level config fix.

No repository should carry a local override of this grouping rule: the coupling is a
property of the dependency pair, not of any one consumer.
