---
date: 2026-07-25
issue: 143
title: Merge gate treats absent CI checks as not-green
---

Closes the second, deeper defect in #143: the gate concluded "CI green" whenever
nothing in the filtered `statusCheckRollup` was pending — which is also true when
the rollup is **empty**. A workflow that dies with `startup_failure` produces no
check run at all, so a PR that was never built, tested or linted looked identical
to a fully green one and was auto-merged.

`ci_wait` now (a) never calls an empty rollup green — it ends with
`::error::phase=ci-wait result=no-checks` plus the remediation, never a silent hang;
(b) probes `actions/runs?head_sha=…` before concluding green and fails closed naming
any `startup_failure` workflow; (c) treats an unusable probe as inconclusive
(`result=probe-unavailable`), never green — including a 2xx whose body jq cannot
parse, is empty, or lacks `workflow_runs`, since jq exits 0 on an empty body and
swallowing its error would have re-opened the very hole this closes; and (d) rejects
a head SHA that isn't 40 hex (`result=unknown-head`) — `jq -r .headRefOid` prints the
literal `null` for a missing key, which is non-empty and makes the probe query a
commit that doesn't exist. The authoritative merge recheck repeats the same checks in
the same order, with a bounded 3-attempt probe retry so one transient API blip
doesn't discard an already-paid-for model review.

Because a `paths:`-filtered workflow that doesn't match emits **no check run** (this
repo's own CI is path-filtered), absence is now decided after a ~5 minute grace
period instead of the full 30–40 minute window, and a bounded opt-out
`allow_absent_checks` (default **false**/strict, exposed on `workflow_dispatch` and
`workflow_call`) gives a legitimately check-free PR a path forward; engaging it logs
`result=no-checks-allowed` as a warning and still refuses a `startup_failure`. The
`SUCCESS`/`NEUTRAL`/`SKIPPED` allowlist, `renovate/stability-days` handling, and the
fast/ai attempt ceilings are unchanged.

Note for operators: both probes run under `ORG_ADMIN_TOKEN`, so the job-level
`permissions: actions: read` does not cover them — that secret must itself carry
Actions:read on every gate-target repo or those repos fail closed on every PR.

Covered by `scripts/ci-gate/ci-wait-fail-closed.test.sh` (wired into `actions-ci`).
Test-harness fixes shipped alongside: the shared `run:`-block extractor bled every
following step into the script under test (`ci_wait` extracted as 529 lines), so the
rc=0 positive controls were asserting unrelated code; and the `gh api` stubs in
`hold.test.sh` / `gate-queue.test.sh` returned empty stdout, which the old code read
as "probe ok" — they were passing by way of the bug. Rationale in ADR 0024. The
startup-failure trigger itself was already fixed in e3cf463/b2e57be — untouched
here. Refs #143, ADR 0024.

Review follow-ups, before this shipped: the startup-failure verdict keyed on the
joined workflow **name** string, but `name` is nullable and `[null] | join(", ")`
is `""` — so a run that died parsing its own YAML, the literal #143 case, still
read as clean. Both steps now branch on a **count**; names are log text only.
And `runs_seen` counted the gate's **own** run — the gate is a workflow run on
the head, so the count was never zero and the prompt-`no-checks` shortcut was
unreachable; every untriggerable PR burned the full window. It now excludes
`.id == $GITHUB_RUN_ID` (a run id, so it holds for cross-org `workflow_call`
too), and the grace widened 5 → 10 polls now that it can actually fire.
