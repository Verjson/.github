---
date: 2026-08-03
issue: 334
title: Merge-gate jobs take the fast lane when the target repository is public
---

ADR 0047 gave short jobs a fast lane and deliberately left `gate` out of it, on
the grounds that a poll loop wastes a hosted minute exactly as it wastes a
self-hosted one. That is true about waste and wrong about starvation, and
starvation was the actual failure: sleepers only block anyone on a **fixed-size**
pool. Hosted capacity is elastic, so a sleeping gate blocks nobody.

The evidence is that the fast lane did not unjam anything. `preflight`, `gate`
and `dispatch-merge` were still on the shared pool, so they were still what
queued — this repository's own `preflight` sat 19 minutes behind four
`privileged_merge` poll loops after ADR 0047 had already shipped. Routing
`shell-tests` moved the job that was not the problem.

All three now take `VERJSON_RUNNER_FASTLANE` when the target repository is
**public**, and stay self-hosted otherwise. Public repositories run hosted at $0;
private ones meter against a limit that was hit at exactly $20.00 on 2026-07-17,
and `gate` is the longest job on every pull request, so routing private targets
would have been the most expensive change available.

`preflight` keys on the event's repository because it is the job that resolves
visibility; `gate` and `dispatch-merge` key on its output, because on the
dispatch path the event repository is the dispatcher rather than the target. The
test is `== 'false'` rather than `!= 'true'` so unresolved visibility falls
through to the fleet that is already paid for — the failure mode being guarded
against is a bill. `runner-routing-policy.test.sh` pins both polarities and its
evaluator now models `needs`; the `!= 'true'` mutant fails it.

Untrusted public PR code also stops running on a persistent runner and starts
running on a disposable VM, which is the isolation ADR 0033 wanted built.

Unchanged: the gate still holds a runner while waiting. Elastic capacity stops
that hurting others; it does not make it efficient, and private targets keep the
old behaviour. See [ADR 0048](docs/decisions/0048-merge-gate-fast-lane-by-visibility/README.md).
