---
date: 2026-08-03
issue: 346
title: actionlint takes the fast lane on public targets, so the gate stops waiting on a starved job
---

ADRs 0047 and 0048 moved the merge gate onto elastic hosted capacity but left
the jobs it *waits on* behind. The gate got cheaper at waiting; nothing it waits
for got faster.

Measured on this repository's own PR #339: `actionlint` and `npm-cache-seed`
queued at 13:45:36Z and were still unassigned twelve minutes later while `gate`
polled for them, with 6/6 self-hosted runners busy. Organization-wide at that
moment, roughly fifteen runs were queued and `verjson-payments`' `build-test`
had been waiting **45 minutes**.

`actionlint` now routes to `VERJSON_RUNNER_FASTLANE` on a public target. It is
short, secretless and pure CPU, so a public repository's linter no longer
competes with merge-gate poll loops for a fixed pool, and a public target's
hosted minutes are free under ADR 0048. Private targets are unchanged.

The predicate is `visibility == 'public'`, **not** `private == false`. Actions
coerces an absent `private` to `0`, and `0 == false` is true, so the obvious
form routes an *unreadable* repository to the fast lane. `visibility` is a
string; unresolved gives `''`, which falls through to the self-hosted untrusted
pool. The fail-open version was written first, passed all three positive cases,
and failed only the unresolved one — see
[ADR 0050](docs/decisions/0050-actionlint-fast-lane-for-public-targets/README.md).

Writing the test exposed why this went untested for so long: `actionlint.yml`
was only ever *grepped*, never evaluated, because `inputs.github-hosted-runner`
is a legal Actions reference and an illegal JavaScript one — it parses as
`inputs.github - hosted - runner` and threw in the shared expression evaluator.
The evaluator now rewrites it, so four polarities are pinned, plus a mutation
check that the fail-open form stays absent.

Deliberately unchanged: `npm-cache-seed`, the other job starving #339. It
validates the persistent runner's local npm cache, so a disposable hosted VM
would delete the thing under test. Its problem is coupling rather than routing —
a cache probe should not be a per-PR check an unrelated merge gate blocks on —
and #346 stays open for it.
