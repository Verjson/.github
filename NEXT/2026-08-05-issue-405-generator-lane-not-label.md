---
date: 2026-08-05
issue: 405
title: Stop baking a fleet label into every generated privileged-merge caller
---

`scripts/gen-privileged-merge-caller.sh` required a runner-labels argument and
emitted `runner_labels: '["self-hosted","general"]'` into every caller it
produced, because `ai-privileged-merge.yml` and `ai-review-merge.yml` declared
the input `required: true`. #401 cleared every `runs-on:` in this repository onto
lane variables, so the generator was the last place the org handed a fleet label
to consumers — one that only a pull request in each of ~90 repositories could
change. `Verjson/verjson-identity-lifecycle` carries the literal today.
`actionlint` cannot catch the class: its undeclared-label check inspects
`runs-on` arrays, and a label inside a string input is invisible to it.

`runner_labels` is now `required: false` in both workflows, and the generator's
argument is optional — omitted, it emits no `runner_labels` and no fleet label
anywhere in the file, including the regenerate command an operator copies. The
input is kept, not deleted: a self-hosted consumer **outside** Verjson has no
`VERJSON_LANE_*` variables to fall through to, so it must still be able to name
its own fleet, and `inputs.runner_labels` keeps its first place in the `runs-on`
precedence chain **on the jobs that read it** — `preflight`, `gate` and
`privileged_merge`. `dispatch-merge` never has, so a self-hosted-only caller
outside Verjson gets one job on `ubuntu-24.04`; that predates this change and is
filed as [#411](https://github.com/Verjson/.github/issues/411). The requirement's
original justification (#130 — an omitted input queued the job forever on
`self-hosted,gate`) expired when every chain gained the
`VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]'` tail.

The consumer-facing comment in `ai-review-merge.yml` is qualified rather than
left absolute: the example caller pins `@v1`, and `v1` still declares the input
required until a release cuts after this, so a consumer that followed unqualified
guidance would get `Input runner_labels is required, but no value was supplied`.
The generated privileged caller pins `@main` and is unaffected.

`privileged-merge-caller-contract.test.sh` asserts a generated caller contains no
`self-hosted` literal, omits the input, and still forwards an explicit fleet;
`runner-routing-policy.test.sh` now models `inputs.runner_labels` and evaluates
the real `runs-on` expression for both polarities — omitted routes through
`VERJSON_LANE_PRIVILEGED`, supplied wins for an off-Verjson fleet. It also models
`VERJSON_RUNNER_OVERFLOW`, which the org sets today and which precedes the lane
variables in every `ai-review-merge.yml` chain: leaving it off `vars` made the
omitted-input case assert a route production cannot take, so the gate polarity is
now asserted with the overflow lane both unset and set.
`reusable-workflow.test.sh` pins `required: false` with the reason it changed.

Existing generated callers keep working — they pass a still-accepted input — but
remain label-pinned until the #365 consumer sweep regenerates them, which must
land after this. The decision is recorded as
[ADR 0057](docs/decisions/0057-runner-labels-optional-lane-routed-callers/README.md),
which supersedes the `runner_labels` requirement in ADRs 0022 and 0042 and
narrows ADR 0053's exclusion; those three carry a pointer rather than a rewritten
body. It is a sensitive-class decision: with the input gone from generated
callers, whoever can write `VERJSON_LANE_PRIVILEGED` places the job that holds
`ORG_ADMIN_TOKEN`, with no pull request in any consumer repository.

Tracks [#405](https://github.com/Verjson/.github/issues/405).
