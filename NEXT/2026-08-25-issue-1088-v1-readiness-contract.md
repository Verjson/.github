---
date: 2026-08-25
issue: 1088
impact: minor
title: Publish the organization v1.0.0 readiness contract
---

Add `docs/v1-readiness/README.md`, the canonical checklist a `@verjson/*` package must
clear before its version is cut to `v1.0.0`, and ADR 0137 recording the decision to cut
`v1.0.0` across the pre-1.0 set, the dependency-derived release order, and the two-phase
publish-then-bump-consumers rollout.

Below `1.0.0` the minor position carries the breaking-change role, so `^0.1.3` refuses
`0.2.0` and a guardrail published as a `0.x` minor reaches nobody. `1.0.0` makes the caret
range bind — and makes a mislabelled patch propagate silently, which is why the cut is
gated on a readiness bar rather than done as a bulk version bump. Every item in the bar is
grounded in a defect observed in this organization on 2026-08-25: the `CodeStore` port
break shipped as a patch (`Verjson/verjson-authn#244`), the missing `exports` map
(`Verjson/verjson-tsconfig#34`), the `^0.2.0` peer range that already `ERESOLVE`s
(`Verjson/verjson-authz#125`), and the exact-version compatibility matrix that retention
deleted out from under two unrelated pull requests (`Verjson/verjson-authz#124`).

`impact: minor` is deliberate and not the contract's `patch` fallback: this adds a new
consumer-facing contract surface that per-repository prep issues reference at a SHA,
without changing the behaviour of any existing workflow, script, or pin. Declaring it
explicitly is itself readiness item 6 — an absent `impact:` is a defect, not a default,
and is the exact mechanism that made the `verjson-authn` `1.0.2` break invisible.

Rollout is tracked by #1088. The wave is blocked on landing `Verjson/verjson-authn#246`,
the reference implementation of the published-type-surface conformance check.
