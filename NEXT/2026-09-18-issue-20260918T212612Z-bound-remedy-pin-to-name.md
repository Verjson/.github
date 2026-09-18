---
date: 2026-09-18
id: 20260918T212612Z
title: Bound the generated-set remedy pin's claim to the name it matches
impact: patch
---

The pin added for #1369 over `generated_set_check`'s remedy handling carried a claim that
touching `$remedy` anywhere else in the generator "reddens that pin". Measured against the
pin itself, that is false in one direction, and the claim is the artifact a later reader
trusts instead of re-deriving the property.

The pin selects body lines containing the substring `remedy` and classifies each one. So a
write that names the variable is caught: injecting `remedy+=" | tee /dev/null"` before arm 0
makes `merge-gate` exit 1 with one `FAIL -`. A write that never spells the name is not
merely unclassified — it is never examined. Injecting a poisoned remedy through
`printf -v "$__rv"`, with `__rv` assembled as `"rem"` + `"edy"`, ships fully green:
`merge-gate` exit 0, zero `FAIL -`.

Closing that would mean interpreting the function body rather than reading it, which is a
different kind of check and a different cost. The limit is now stated on all three surfaces
that carry the claim — the generator comment, the gate comment, and the round-4 fragment —
so the honest form is recorded: every form that names `$remedy` is caught and fails closed,
and the indirect forms are a known blind spot rather than a guarantee.

This fragment carries an `id:` identity rather than `issue: 1369` because the #1369 fragment
has already landed on `main`; two fragments sharing one identity fail validation, while a
production-source change with no newly added fragment fails `check-pr`.
