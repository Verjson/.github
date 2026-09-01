---
date: 2026-09-01
issue: 1219
impact: minor
title: Renovate-deferred CI is now legible to the pre-merge assertion
---

`node-ci.yml`'s `build-test` job always reports a conclusion so a held
Renovate PR never wedges the required `ci / build-test` context (#191), but
that meant a stability-window deferral — every step skipped, only the
`Report deferred CI` notice ran — was byte-for-byte indistinguishable from a
real pass at the merge gate. `Verjson/verjson-graphql-conventions#66` showed
the resulting hazard: a lockfile bump with a real, locally-reproducible test
failure carried a fully green `statusCheckRollup`.

Per ADR 0156, the deferral notice is now titled (`::notice title=CI
deferred::...`), and a new canonical script,
`scripts/assert-no-deferred-checks.sh <owner/repo> <pr-number>`, strengthens
the documented `statusCheckRollup` one-liner by additionally rejecting any
completed check run whose annotations carry that title. Operators and agents
performing an `--admin` merge should adopt this script in place of the bare
rollup assertion; see the ADR for the scope boundary around the external
`verjson-agents` procedural documentation, which this change does not edit.
