---
date: 2026-09-17
issue: 1411
impact: patch
title: Say that ruleset drift reports compare asserted fields, not whole images
---

The authorization-arm audit's drift reports now describe the comparison they
actually run: `main-protection matches neither reviewed image on the fields the
contract asserts`, and the arm and deterministic reports name "the fields its
reviewed image asserts".

The comparison stopped being whole-object in #1404 / ADR 0188, which pins the
fields the contract asserts and tolerates keys GitHub adds to its own schema.
The reports kept the pre-#1404 wording ("full reviewed preimage and postimage",
"its full reviewed image"), which reads as exact equality and would send a
maintainer hunting for drift in keys the contract never pinned. Wording only —
no comparison behavior changes. ADR 0188's historical quote of the original
failure is left intact, because it records what the audit printed at the time.
