# 0024 — Absent CI checks fail the merge gate closed

- **Date:** 2026-07-25
- **Issue:** Verjson/.github#143
- **PR:** #144
- **Category:** merge-gate behaviour (sensitive class)

## Context

The gate decided "CI is green" from the PR's `statusCheckRollup`, filtered down to
the non-gate checks: red if any check failed, wait if any is pending, **green when
nothing is pending**. That last rule silently equates *absence* of a check with a
*passing* check.

#143 produced the failure in the wild. `node-ci.yml@main` referenced a co-located
composite action by a ref the runner could not resolve, so the consumer's workflow
died with `startup_failure` — a state that produces **no check run at all**. The
consumer PR's filtered rollup was therefore `[]`: nothing failed, nothing pending,
so the gate concluded green and auto-merged a PR that was never built, tested or
linted. The startup breakage itself is already fixed (e3cf463, b2e57be); the gate
logic that turned it into an unreviewed auto-merge was not.

The same blind spot is reachable without a startup failure: a workflow whose
trigger never matched, a repo whose CI was removed, or an org-CI misconfiguration
all present as "no checks" and were all treated as green.

## Decision

Treat absence as *not green*, at both places the gate reads CI, and make every
fail-closed exit say why.

1. **An empty post-filter rollup is never green.** In `ci_wait` it keeps polling
   (a check can still appear) and, if it is still empty when the lane's poll
   window ends, the step fails with `::error::phase=ci-wait result=no-checks`
   naming the head SHA and the remediation. It does not hang silently.
2. **Probe for the state the rollup cannot express.** Before concluding green, the
   gate reads `repos/{repo}/actions/runs?head_sha={head}` and fails closed on any
   run whose conclusion is `startup_failure`, naming the workflow(s) —
   `result=startup-failure workflows=node-ci`. The runs API is used rather than
   `commits/{sha}/check-suites` because it carries the **workflow name**, which is
   what makes the error actionable; the gate job already holds `actions: read`.
3. **An unverifiable probe is inconclusive, never green.** An API failure retries
   inside the poll window and, if it never recovers, ends in
   `result=probe-unavailable` rather than a misleading `result=timeout`.
4. **An empty `EXPECTED_HEAD_SHA` fails fast** (`result=unknown-head`): an
   unfiltered runs query matches every recent run in the repo and would blame this
   PR for an unrelated commit's startup failure. The head cannot appear mid-run,
   and the merge step already refuses an empty head, so nothing could have merged.
5. **The authoritative merge recheck (`id: merge`) gets the same two absence
   checks.** It is the step that actually squash-merges — an irreversible act —
   and it re-reads the rollup itself precisely because the earlier snapshot may be
   stale. A workflow re-dispatched onto the same head can start failing after
   `ci_wait` passed, and a defence that is skipped at the moment of the merge is
   not a defence. It fails closed immediately (no polling — the step is
   deliberately a single snapshot; ADR #104's shape is preserved).

Unchanged: the `SUCCESS`/`NEUTRAL`/`SKIPPED` conclusion allowlist, the
`renovate/stability-days` StatusContext handling (a pending context is *presence*,
so it still polls and still ends as `result=timeout`), the 60/80-attempt fast/ai
lane ceilings, and the `phase=ci-wait` / `phase=merge-recheck` log vocabulary.

## Consequences

- A PR that genuinely has **no CI at all** no longer auto-merges. It burns its
  poll window and fails with `result=no-checks`. That is the intended trade
  (fail-closed beats merging unbuilt code), but a repo that deliberately has no
  workflows for some path must now surface *some* check — e.g. a skipped job still
  reports `SKIPPED`, which is accepted — rather than reporting nothing.
- Two extra `gh api` calls per gate run in the common case (one per snapshot);
  the probe only runs on the path to green, not on every poll.
- Two existing test fixtures modelled "green" as an empty rollup
  (`hold.test.sh` positive control, `gate-queue.test.sh` `run_wait`). Their intent
  is unchanged; they now carry a real passing check and the job-level
  `EXPECTED_HEAD_SHA` the step consumes.
- Covered by `scripts/ci-gate/ci-wait-fail-closed.test.sh` (wired into
  `actions-ci.yml`), which extracts both shipped `run:` blocks and exercises
  empty / startup-failure / green / red / pending-context / probe-failure /
  unknown-head.

## Effective diff (sensitive hunks)

```diff
           if [ -z "$pending" ]; then
+              # Nothing left pending — but before calling it green, probe for the
+              # failure mode the rollup cannot express: a workflow that died with
+              # `startup_failure` never produces a check run (#143).
+              if runs_json=$(gh api "repos/$TARGET_REPO/actions/runs?head_sha=$EXPECTED_HEAD_SHA&per_page=100" 2>/dev/null); then
+                probe=ok
+                broken=$(jq -r '[.workflow_runs[]? | select(((.conclusion // "") | ascii_downcase) == "startup_failure") | .name] | unique | join(", ")' <<<"$runs_json" 2>/dev/null || echo "")
+              else
+                probe=unavailable
+                echo "::warning::phase=ci-wait result=probe-unavailable elapsed_seconds=$elapsed attempt=$i/$max_attempts head=$EXPECTED_HEAD_SHA"
+                sleep 30
+                continue
+              fi
+              if [ -n "$broken" ]; then
+                echo "::error::phase=ci-wait result=startup-failure elapsed_seconds=$elapsed lane=$LANE head=$EXPECTED_HEAD_SHA workflows=$broken"
+                exit 1
+              fi
+              # Absence of a check is NOT a passing check (#143).
+              if [ "$checks" -eq 0 ]; then
+                echo "phase=ci-wait elapsed_seconds=$elapsed attempt=$i/$max_attempts checks=0 pending=<none-reported>"
+                sleep 30
+                continue
+              fi
             elapsed=$(( $(date +%s) - started_epoch ))
-              echo "::notice::phase=ci-wait result=green elapsed_seconds=$elapsed attempts=$i lane=$LANE"
+              echo "::notice::phase=ci-wait result=green elapsed_seconds=$elapsed attempts=$i checks=$checks lane=$LANE"
             exit 0
           fi
...
+          if [ "$probe" = "unavailable" ]; then
+            echo "::error::phase=ci-wait result=probe-unavailable elapsed_seconds=$elapsed lane=$LANE head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
+          if [ "$checks" -eq 0 ]; then
+            echo "::error::phase=ci-wait result=no-checks elapsed_seconds=$elapsed lane=$LANE head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
           echo "::error::phase=ci-wait result=timeout elapsed_seconds=$elapsed lane=$LANE pending=$pending"
           exit 1
```

```diff
           if [ -n "$pending" ]; then
             echo "::error::phase=merge-recheck result=pending ... pending=$pending"
             exit 1
           fi
+          # Fail closed on ABSENT CI, not just red or pending CI (#143). This
+          # snapshot squash-merges, so it repeats both absence checks itself.
+          if [ "$(jq 'length' <<<"$rollup")" -eq 0 ]; then
+            echo "::error::phase=merge-recheck result=no-checks ... head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
+          if runs_json=$(gh api "repos/$REPO/actions/runs?head_sha=$EXPECTED_HEAD_SHA&per_page=100" 2>/dev/null); then
+            broken=$(jq -r '[.workflow_runs[]? | select(((.conclusion // "") | ascii_downcase) == "startup_failure") | .name] | unique | join(", ")' <<<"$runs_json" 2>/dev/null || echo "")
+          else
+            echo "::error::phase=merge-recheck result=probe-unavailable ... head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
+          if [ -n "$broken" ]; then
+            echo "::error::phase=merge-recheck result=startup-failure ... workflows=$broken"
+            exit 1
+          fi
           if [ "$LANE" = "fast" ]; then
```

Full change: https://github.com/Verjson/.github/pull/144
