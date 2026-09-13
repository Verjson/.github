---
date: 2026-09-13
id: 20260913T173500Z
title: Group pydantic and pydantic-core so Renovate never bumps one without the other
impact: patch
---

`pydantic-core` is `pydantic`'s compiled Rust backend; the two are version-coupled
upstream, and a lockstep bump of only one risks pairing an unsupported combination.
`verjson-editor#123` bumped `pydantic-core` alone in
`benchmarks/unstructured/requirements.txt` (pinned at `pydantic==2.13.5` /
`pydantic-core==2.46.5`) while a separate open PR bumps `pydantic` — exactly the
split-bump risk this closes. A new `packageRules` entry groups `pydantic` and
`pydantic-core` across `pip_requirements`, `pep621`, and `poetry` so every consumer
repo gets one PR that bumps both together, matching the existing "github actions
digests" group's rationale for coupled dependencies.

No repository should carry a local override of this: `pydantic`/`pydantic-core`
coupling is a property of the dependency pair, not of any one consumer.
