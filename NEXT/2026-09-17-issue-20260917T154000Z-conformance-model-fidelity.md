---
date: 2026-09-17
id: 20260917T154000Z
title: The conformance model no longer manufactures the evidence it demands
impact: patch
---

An independent review of the conformance matrix (#1369, landed in #1386)
found the harness reproducing,
in itself, the defect class it exists to catch. Two modelling errors:

- A step that failed did not stop the job. Every later step — including the
  step whose execution *is* the positive evidence the matrix asserts — was
  still counted as executed, so the harness could report evidence of execution
  for steps GitHub would have skipped.
- An indented `exit 1` inside a bash conditional was read as unconditional, so
  five guarded error paths were treated as certain failures and the healthy
  secretless lane was modelled as red throughout. Nothing caught it, because
  nothing asserted that a lane which runs concludes successfully.

Only a top-level `exit <non-zero>` now terminates a job; later steps stop
accumulating unless their guard runs after failure; and an unguarded job whose
dependencies did not all succeed is modelled as skipped rather than as running.
That last one matters on its own: deleting `if: always()` from a required job
is exactly the defect class this matrix exists to catch, and it previously
passed.

The assertions were also weaker than they read. The deferral property accepted
a non-SUCCESS conclusion from *any* job, so a spurious failure anywhere in the
contract satisfied it and looked identical to conformance; it now requires the
deferred run to publish `deferred-ci` and nothing else. The evidence property
accepted any non-empty intersection, so a contract that guarded off `npm test`
while leaving `npm ci` running passed; each lane must now execute exactly the
work that defines it.

Verified by mutation rather than by assertion count: deleting `if: always()`
from `build-test`, replacing the `npm test` guard, and failing the job
unconditionally each fail the suite, and each failed a different property.

Two further guards on the harness itself. The counter-example is asserted to
differ from the contract by the `deferred-ci` job alone — it is a YAML
round-trip, so it cannot be compared byte for byte and would otherwise drift
into a tautology. And the evaluator raises its own typed error on a name
nothing bound, instead of a bare `NameError` that reads as a harness crash
rather than as an unmodelled guard.

A second review round found the after-failure skip short-circuiting *before* the
guard was evaluated, so a step following a failed one escaped the evaluator
entirely and an unbound context there would no longer raise — the fail-closed
property this module is built on, reopened in a narrow window. The guard is now
evaluated first and the skip conjoined to it. Two related corrections: GitHub
drops the implicit `success() &&` when a guard names any status function, so
`success()` belongs in the set of guards that still run after a failure; and a
heredoc body sits at column 0 of the parsed block scalar, so a `cat <<'SH'`
carrying `exit 1` would have been read as terminating the job — the
indented-`exit` defect returning through another door, in a contract with
roughly eighteen heredocs.
