---
date: 2026-09-23
id: 20260923T104554Z
impact: patch
title: Retire the fulfilled merge-gate guidance proposal
---

Remove the temporary merge-gate guidance proposal after the authoritative change lands as
[Verjson/verjson-agents#412](https://github.com/Verjson/verjson-agents/pull/412). The proposal was tracked by
[Verjson/.github#1421](https://github.com/Verjson/.github/issues/1421); the adopted
guidance now directs privileged merges through the canonical fail-closed assertion, binds
the validated head SHA, and names all reads the helper performs. Correct the helper's own
permission message to match those reads.
