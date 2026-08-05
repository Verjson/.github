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
precedence chain. The requirement's original justification (#130 — an omitted
input queued the job forever on `self-hosted,gate`) expired when every chain
gained the `VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]'` tail.

`privileged-merge-caller-contract.test.sh` asserts a generated caller contains no
`self-hosted` literal, omits the input, and still forwards an explicit fleet;
`runner-routing-policy.test.sh` now models `inputs.runner_labels` and evaluates
the real `runs-on` expression for both polarities — omitted routes through
`VERJSON_LANE_PRIVILEGED`, supplied wins for an off-Verjson fleet.
`reusable-workflow.test.sh` pins `required: false` with the reason it changed.

Existing generated callers keep working — they pass a still-accepted input — but
remain label-pinned until the #365 consumer sweep regenerates them, which must
land after this. ADRs 0022, 0042 and 0053 are amended with the dated rationale.

Tracks [#405](https://github.com/Verjson/.github/issues/405).
