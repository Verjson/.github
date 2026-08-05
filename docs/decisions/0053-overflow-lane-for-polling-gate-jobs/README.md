# 0053 — One reversible overflow lane for jobs that poll the pool they wait on

- **Date:** 2026-08-05
- **Issue:** Verjson/verjson-github-runner#118
- **Category:** CI routing / throughput
- **Status:** Accepted

## Context

ADR 0050 moved public-target gate work to hosted runners because a gate job
**sleeps while polling for CI it cannot influence**, so on a fixed pool the
sleepers starve the CI they are waiting for. That reasoning is already recorded
in `ai-review-merge.yml` immediately above the `runs-on` expression.

The fix was applied only to the `target_private == 'false'` branch. The
organization has **2 public repositories and 88 private ones**, so in practice
almost every gate still lands on the shared persistent lane, and the deadlock
ADR 0050 describes is the normal case rather than the exception.

Measurements on the `general` lane (80 job samples across five active
repositories, 2026-08-05):

| job | n | mean queue | mean runtime | queue ÷ runtime |
|---|---|---|---|---|
| `ci (24) / eligibility` | 2 | 4015 s | 3 s | **1338×** |
| `ci (20.20.2) / eligibility` | 2 | 2581 s | 4 s | 737× |
| `changelog / validate` | 5 | 1531 s | 9 s | 166× |
| `ci (20.20.2) / build-test` | 2 | 8794 s | 62 s | 142× |
| `gate` | 8 | 408 s | 580 s | 1× |
| `privileged_merge` | 15 | 586 s | 216 s | 3× |

Aggregate: **31 406 s queued against 11 103 s of runtime — 2.8× more time
waiting than working.** A 30-minute sample found all ten runners busy in 60
consecutive observations without a single idle one.

`gate` (42% of lane runtime) and `privileged_merge` (29%) together consume 71%
of the lane, and both are dominated by polling — `max_attempts=60`–`80` at
`sleep 30`, i.e. up to 30–40 minutes of occupying a runner slot while doing no
work, waiting on jobs that need a slot from the same pool.

Two consequences follow, and the second is the expensive one:

1. Jobs that run for seconds wait for tens of minutes.
2. The lane cannot be maintained. `verjson cloud runner update` requires a
   target runner to be online *and idle* before it will mutate it; at
   sustained 10/10 busy that state never occurs, so image rotations and the
   migration of the three hosts still on legacy installs cannot proceed.

Adding capacity is not currently available, and hosted minutes are finite:
July consumed 7 514 minutes against a 3 000-minute Team allowance, at $20 of
overage.

## Decision

Introduce a single organization variable, **`VERJSON_RUNNER_OVERFLOW`**,
consulted ahead of `VERJSON_RUNNER_UNTRUSTED` and `VERJSON_RUNNER_DEFAULT` in
`ai-review-merge.yml`, `changelog-validate.yml`, and `changelog-release.yml`.

```
vars.VERJSON_RUNNER_OVERFLOW || vars.VERJSON_RUNNER_UNTRUSTED || vars.VERJSON_RUNNER_DEFAULT || '["self-hosted","general"]'
```

Setting it to `["ubuntu-24.04"]` moves those jobs to hosted runners. **Unsetting
it restores the previous routing exactly**, with no code change, no pull
request, and no redeploy — which is the property that matters, because hosted
capacity here is a budget that will be exhausted and must then be given back.

When the variable is absent the expression is byte-equivalent in behaviour to
the previous one, so this change is inert until someone opts in.

## Consequences

The intended effect is not primarily that the moved jobs get faster. It is that
**the polling sleepers stop occupying the pool they are blocking**. Freeing 71%
of lane runtime is worth roughly seven additional runners without provisioning
any, and it restores the idle windows that fleet maintenance requires.

The cost is self-limiting in a useful way: gate runtime is inflated *by* the
deadlock, so once gates no longer starve the CI they poll for, they finish
sooner and bill fewer hosted minutes than the current 580 s mean implies.

This does not change any trust property. The gate's guarantees are runner
independent, and hosted VMs are better isolation for untrusted PR head code
than a persistent shared runner — the same argument ADR 0050 already accepted.

### Why `dispatch-merge` is included, and why that is the load-bearing part

A concrete instance recorded on #341: `privileged_merge` polled for 41 minutes
and failed with `trusted gate/checks did not become green`, when every real
check on the PR had already passed and the **only** outstanding one was
`dispatch-merge` — the gate's own downstream job, which could not get a runner
because the gate was holding one. A gate starving its own successor.

`dispatch-merge` resolves through `VERJSON_RUNNER_ISOLATED`, a different chain
from the one the other jobs use, so it is covered explicitly here. This is the
reason the change works without moving `ai-privileged-merge.yml` at all: put the
job the poller is *waiting on* onto elastic capacity, and the poll completes
instead of deadlocking. Moving the waiter is neither necessary nor sufficient;
moving the awaited job is both.

That failure mode also has a cost beyond latency, which #341 records: a red
`privileged_merge` is visually indistinguishable from a real code failure, so it
trains reviewers to merge past red — the exact habit a privileged merge gate
exists to prevent. `verjson-cli-projects#57` merged with it red.

`ai-privileged-merge.yml` is **deliberately excluded**, even though it is 29% of
lane runtime and the most frequent job. Its runner comes from
`inputs.runner_labels`, which every consumer's generated caller passes, so an
organization variable cannot override it without inverting the precedence
between a caller input and organization configuration on the one workflow that
carries merge authority. Moving it means regenerating the callers, which should
be a deliberate, separately reviewed change rather than a variable flip.

> **Amended 2026-08-05 (#405).** The generator no longer emits `runner_labels`,
> so a **newly generated** caller is lane-routed and an organization variable does
> reach it. The exclusion still holds for callers generated before #405: they keep
> passing the input until the #365 sweep regenerates them, which is the deliberate,
> separately reviewed change this paragraph asks for.

## Reverting

```sh
gh variable delete VERJSON_RUNNER_OVERFLOW --org Verjson
```

Effective for every workflow run started afterwards. No other action required.
