---
date: 2026-08-22
issue: 933
impact: minor
title: Detect live generated-caller pins that predate an assumed capability
---

Adds a two-stage generated-caller capability-floor observer (ADRs 0114 and
0135). A scheduled and manually dispatched, report-only workflow reads an
explicit reviewed consumer allowlist using an exact-repository,
`contents:read` App token, strictly extracts immutable canonical pins, and
feeds them to the local Git-ancestry classifier. Malformed or inaccessible
callers fail closed; stale findings remain non-mutating summary and artifact
evidence.

Stage A stores capability facts and classifies `{repo, generator, pinned_sha}`
snapshots with `git merge-base --is-ancestor`. Stage B binds every consumer
read to its resolved default-branch commit, retains source/blob receipts, and
accepts pins only from duplicate-key-safe parsed `jobs.<job>.uses` targets,
rejecting scalar/step decoys. It never enumerates or mutates organization repositories. The observer reuses
the existing read-only Renovate Compatibility App without broadening its live
installation permissions.
