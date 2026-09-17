---
date: 2026-09-17
issue: 1364
title: Assert that verification executed, not merely that nothing is red
impact: minor
---

The organization's pre-merge assertion collapsed four materially different head
states into one bare `false`: a genuinely failing required check, an ADR 0178
deferral where nothing ran, a required check that never reported at all, and a
red advisory check. The cheapest way to clear an opaque `false` is to widen the
accepted-conclusion list, and the first entry anyone widens it to accept is the
`deferred-ci` `FAILURE` that makes an otherwise-green Renovate pull request look
broken — which restores exactly the `Verjson/verjson-cli#251` condition ADR 0178
was written to end.

`scripts/assert-mergeable-head.sh` replaces that boolean with three separately
named gates, each failing closed with its own exit code and message: required
contexts read from the **base ref's ruleset** rather than inferred from the head,
and matched on exact name **plus the app the ruleset binds them to** (Gate A);
positive evidence that verification executed — no `deferred-ci` that ran, no
ADR 0156 deferral annotation (Gate B); and nothing else pending or non-passing
(Gate C). Relaxing the gate now requires naming which gate is being relaxed, and
no gate's matching rule is configurable from the environment.

The app binding matters: matching a required context on display name alone lets
any workflow satisfy it by naming a job after it, which is the ADR 0024
absent-check class arriving from a direction branch protection is not vulnerable
to. The check inventory therefore comes from `commits/{sha}/check-runs` and
`commits/{sha}/status`, not from `statusCheckRollup`, which carries no app id.

`scripts/assert-no-deferred-checks.sh` is unchanged and not retracted, so no
existing caller becomes silently stricter. The new script additionally reads
`repos/{repo}/rules/branches/{ref}` and refuses to pass a ref that declares no
required checks, which is why it ships as a new entry point rather than as an
in-place upgrade. See ADR 0184.
