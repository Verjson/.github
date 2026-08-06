---
date: 2026-08-06
issue: 460
title: 'chore(actions): retire node-release.yml in favour of a dispatched release'
---

`node-release.yml` refuses to run. Its first step, before any checkout and with
no condition, names `changelog-release.yml` as its replacement and exits 1.

It ran `semantic-release`, which derives the version from commit subjects at
merge time — the model ADR 0038 replaced with a `workflow_dispatch` that states
the version to cut and snapshots the accumulated `NEXT/` fragments into an
immutable `CHANGELOG/<version>.md`.

The workflow is refused rather than deleted so the error can point somewhere: a
deleted reusable fails with "workflow not found", which names neither the cause
nor the replacement. The refusal is unconditional rather than filtered to
`push`, because the defect is deriving a version from commits, not the trigger
that starts it.

`@v1` consumers are unaffected — that tag is frozen at a commit predating this.
