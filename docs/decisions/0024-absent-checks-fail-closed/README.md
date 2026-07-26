# 0024 — Absent CI checks fail the merge gate closed

- **Date:** 2026-07-25
- **Issue:** Verjson/.github#143
- **PR:** #145
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
   what makes the error actionable.

   **Token scope requirement.** Both probes run under
   `GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}` (step-level `env`), so the job-level
   `permissions: actions: read` does **not** apply to them — that block governs
   the run's `GITHUB_TOKEN`, which these steps do not use. `ORG_ADMIN_TOKEN` must
   therefore itself carry **Actions: read on every repo the gate targets**
   (org-wide for the Verjson fleet; the consumer's own equivalent under ADR 0022).
   A token without it gets 403, the probe reports `probe-unavailable`, and every
   PR in that repo fails closed. Verify per repo with:
   `gh api "repos/<owner>/<repo>/actions/runs?head_sha=<sha>&per_page=1"`.

   **The startup-failure verdict is a count, never the names string**
   (amended 2026-07-25). `name` is nullable in the runs schema, and the first
   cut of this probe decided on the joined name list — `[null] | join(", ")` is
   `""`, which is byte-identical to "nothing failed at startup". The bug was
   therefore live in exactly the case the ADR was written for: a workflow that
   dies parsing its own YAML is the likeliest one for GitHub to have no name to
   report. jq now emits an explicit startup **count** alongside the names, both
   steps branch on `[ "$startup_count" -gt 0 ]`, and the names are log text only
   (`.name // "<unnamed>"`). Same class as Decision 3: a layer added to close a
   fail-open reintroduced one via a nullable field.
3. **An unverifiable probe is inconclusive, never green — including a 2xx it
   cannot parse.** A non-zero exit is only one failure mode: a proxy or edge cache
   can answer 200 with an HTML error page, a truncated response parses as nothing,
   and jq handed an empty body reads zero documents, emits nothing and *exits 0*.
   Swallowing jq's status (`… 2>/dev/null || echo ""`) turns each of those into an
   empty startup-failure list — byte-identical to "nothing failed at startup", so
   the layer added to close the fail-open reintroduces it. The probe therefore
   keeps jq's exit status **and** asserts the payload shape (`workflow_runs`
   present and an array) via an explicit `ok` marker in jq's output; anything else
   routes to `probe-unavailable`. In `ci_wait` an API failure retries inside the
   poll window and, if it never recovers, ends in `result=probe-unavailable`
   rather than a misleading `result=timeout`.
4. **`EXPECTED_HEAD_SHA` is validated by shape (`^[0-9a-f]{40}$`), not just
   emptiness** (`result=unknown-head`). `jq -r .headRefOid` prints the literal
   string `null` for a missing key — non-empty, so an `-z` test waves it through —
   and `…/actions/runs?head_sha=null` returns zero runs, letting the probe
   "prove" cleanliness about a commit it never looked at. The value is also
   interpolated into an API URL, so a bare 40-hex SHA is the only acceptable form.
   The preflight producer gained the matching `// ""` fallback.
5. **The authoritative merge recheck (`id: merge`) gets the same absence
   checks.** It is the step that actually squash-merges — an irreversible act —
   and it re-reads the rollup itself precisely because the earlier snapshot may be
   stale. A workflow re-dispatched onto the same head can start failing after
   `ci_wait` passed, and a defence that is skipped at the moment of the merge is
   not a defence. It stays a single snapshot with no polling (the shape settled in
   #104), with one exception: the probe itself retries up to 3 times with a 5s
   backoff, because by this point the model review has already been paid for and
   discarding it over one transient API blip would need a manual re-dispatch.
6. **Fail-closed is the default, not the only outcome: `allow_absent_checks`.**
   A workflow whose `paths:` filter does not match never runs and emits **no check
   run** — unlike a job-level `if:`, which reports `SKIPPED` and is already
   accepted. This repo's own CI is path-filtered (`actions-ci.yml`,
   `actionlint.yml`), so a PR touching only `README.md`, `docs/` outside
   `docs/decisions/`, `profile/`, etc. legitimately triggers nothing, and roughly
   twenty consumer repos have unverified filters. Without an escape hatch such a
   PR is unmergeable by any means (`hold`/draft only *prevent* merging). So a
   boolean input `allow_absent_checks` — **default `false`, i.e. strict** — is
   exposed on both `workflow_dispatch` and `workflow_call` (the latter so
   cross-org consumers under ADR 0022 can set it per call). Engaging it emits
   `::warning::… result=no-checks-allowed` on both steps, so the exception is
   visible in the run log rather than silent. It excuses **absent** checks only;
   a `startup_failure` run still fails closed, as do red and pending checks.
7. **Decide absence promptly instead of burning the window.** When the rollup is
   empty *and* the runs API reports zero runs for the head, nothing was ever
   triggered — a state that cannot change without a push. After a 10-attempt
   (~5 minute) grace period, so a merely slow-to-register check still wins, the
   step takes its terminal decision (fail, or the opt-out path) rather than
   polling a self-hosted runner for the full 30–40 minutes first.

   **"Zero runs" means zero runs other than the gate's own** (amended
   2026-07-25). The gate is itself a workflow run on the PR head, so
   `?head_sha=<head>` always returns at least one run and an unfiltered count is
   never zero — the shortcut above was dead code, and every untriggerable PR
   burned the full 30–40 minute window before failing. The rollup filter strips
   the gate's check *names*; nothing stripped its *run*. `runs_seen` now excludes
   `.id == $GITHUB_RUN_ID`. Matching on run id rather than workflow name is what
   makes this hold for a cross-org `workflow_call` under ADR 0022, where the run
   belongs to the caller and carries the caller's workflow name. The grace was
   widened 5 → 10 at the same time: the shortcut only fires when *nothing* was
   triggered, so the extra polls cost nothing on any real PR and buy margin for
   the runs API lagging the check API.
8. **Say what actually unblocks it.** A `startup_failure` run is permanent for its
   SHA: it is never retried or re-concluded, so fixing the workflow upstream (the
   #143 e3cf463 scenario) does **not** clear it and re-running the gate on the same
   head hits it again. The message now says to push a new commit or delete the
   stale run. The `no-checks` message names the `allow_absent_checks` dispatch
   invocation verbatim.

`ci_wait` and the merge recheck report the same diagnosis for the same repo state:
both probe *before* testing `checks == 0`, so an untriggered-CI PR is reported as
the actionable `startup-failure` where one exists rather than the generic
`no-checks`.

Unchanged: the `SUCCESS`/`NEUTRAL`/`SKIPPED` conclusion allowlist, the
`renovate/stability-days` StatusContext handling (a pending context is *presence*,
so it still polls and still ends as `result=timeout`), the 60/80-attempt fast/ai
lane ceilings, and the `phase=ci-wait` / `phase=merge-recheck` log vocabulary.

## Consequences

- A PR that genuinely has **no CI at all** no longer auto-merges: it fails with
  `result=no-checks` after the ~5 minute grace period. That is the intended
  trade (fail-closed beats merging unbuilt code). The two ways out are to surface
  *some* check — a skipped job still reports `SKIPPED`, which is accepted — or to
  re-dispatch with `allow_absent_checks=true`, which the error message spells out.
- **`ORG_ADMIN_TOKEN` now needs Actions:read on every gate-target repo** (see
  Decision 2). This is the highest-blast-radius consequence: a repo where the
  token lacks it fails every PR closed with `probe-unavailable`. Observed while
  writing this: a PAT with repo scope reads
  `repos/Verjson/.github/actions/runs?head_sha=…` successfully and the response
  carries `total_count` + `workflow_runs` as the shape assertion expects — but
  that was a local CLI token, **not `ORG_ADMIN_TOKEN` itself**, which cannot be
  read from a session. Confirm the secret's own scope before relying on this.
- API cost: on the path to green, two extra `gh api` calls per gate run (one per
  snapshot). On the **empty-rollup path the probe runs on every poll iteration**,
  which is why absence is now decided after ~10 attempts instead of 60–80 — that
  bound is what keeps the worst case at a handful of calls rather than one per
  poll for the whole window. That bound only became real once `runs_seen` stopped
  counting the gate's own run (Decision 7 amendment); before that the empty-rollup
  path always ran the probe on all 60–80 polls.
- Two existing test fixtures modelled "green" as an empty rollup
  (`hold.test.sh` positive control, `gate-queue.test.sh` `run_wait`). Their intent
  is unchanged; they now carry a real passing check and the job-level
  `EXPECTED_HEAD_SHA` the step consumes. Both, plus `gate-queue.test.sh`, also had
  a `gh api` stub that fell through to a bare `exit 0` with empty stdout — which
  the pre-fix code read as "probe ok, nothing broken". They were passing *by way
  of* the swallowed-parse-error bug; they now stub an explicit, well-formed
  no-startup-failures payload.
- The `run:`-block extractor shared by `ci-wait-fail-closed.test.sh`,
  `hold.test.sh` and `gate-queue.test.sh` cleared its capture flag but not its
  step-matched flag, so the next step's `run: |` re-armed capture: `ci_wait`
  extracted as **529 lines** (every following step concatenated) instead of ~100.
  Negative tests survived because each fail-closed path `exit`s, but the rc=0
  positive controls — the two assertions guarding against *over*-blocking — were
  asserting the exit status of unrelated appended code. Capture now stops at the
  next `- name:`.
- Covered by `scripts/ci-gate/ci-wait-fail-closed.test.sh` (wired into
  `actions-ci.yml`), which extracts both shipped `run:` blocks and exercises
  empty / startup-failure / green / red / pending-context / probe-failure
  (non-zero exit, unparseable 2xx body, empty 2xx body, wrong-shape 2xx body) /
  malformed head SHA / prompt no-checks / opt-out (honoured, and refused for a
  startup failure) / stale-probe labelling / merge-probe retry. The suite runs in
  ~2 minutes; most of that is the fake-`sleep` poll loops of the cases that must
  reach the lane ceiling.
- **Fixture realism is load-bearing here** (amended 2026-07-25). The suite
  originally modelled "no workflow runs" as `{"workflow_runs":[]}` — a payload
  production cannot produce, because the gate is itself a run on the head. The
  `runs_seen -eq 0` shortcut therefore passed its test while being dead in the
  real world. Fixtures now include the gate's own run at `id == $GITHUB_RUN_ID`,
  which is also what pins the exclusion. Two more assertions exist purely to pin
  defaults nothing else exercises: a `<unset>` sentinel in the harness removes
  `ALLOW_ABSENT_CHECKS` from the environment (every other case sets it, so the
  `:-false` fallback was otherwise unpinned — flipping it to `:-true` left the
  suite green), and `{"workflow_runs":{}}` — key present, wrong type — is the
  only body that separates the real shape assertion from a vacuous `if true`.
  Each fix in this amendment was verified by mutation: reverting it individually
  turns the suite red.

## Effective diff (sensitive hunks)

```diff
-          if [ -z "${EXPECTED_HEAD_SHA:-}" ]; then
+          # Validate the SHAPE, not just emptiness: `jq -r .headRefOid` yields the
+          # literal "null" for a missing key, and `?head_sha=null` returns zero runs.
+          if ! [[ "${EXPECTED_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
             echo "::error::phase=ci-wait result=unknown-head lane=$LANE"
             exit 1
           fi
+          no_checks_grace_attempts=10
           for i in $(seq 1 "$max_attempts"); do
+            # Reset per iteration: a probe that failed on attempt 1 must not still
+            # be labelling attempt 60's genuine pending timeout as unavailable.
+            probe=unread
...
           if [ -z "$pending" ]; then
+              # Probe for the failure mode the rollup cannot express: a workflow
+              # that died with `startup_failure` produces no check run (#143).
+              # ONE jq pass asserts the payload SHAPE, counts the runs and lists
+              # the startup failures. The explicit `ok` marker — not jq's exit
+              # status — is the test: jq handed an empty body reads zero
+              # documents, emits nothing and still exits 0, so `|| echo ""` (or a
+              # bare `jq -e`) would wave a 2xx HTML error page through as clean.
+              # The verdict is the COUNT, never the names string: `name` is
+              # nullable and `[null] | join(", ")` is "" — see Decision 2.
+              # `runs_seen` excludes the gate's OWN run (`.id == $GITHUB_RUN_ID`),
+              # or the `runs_seen -eq 0` shortcut below is unreachable.
+              probe=unavailable
+              runs_seen=0
+              startup_count=0
+              broken=""
+              if runs_json=$(gh api "repos/$TARGET_REPO/actions/runs?head_sha=$EXPECTED_HEAD_SHA&per_page=100" 2>/dev/null) &&
+                 probe_out=$(jq -r '
+                   ((env.GITHUB_RUN_ID // "") | tonumber? // -1) as $self
+                   | if (has("workflow_runs") and (.workflow_runs | type == "array")) then
+                     ([.workflow_runs[]
+                       | select(((.conclusion // "") | ascii_downcase) == "startup_failure")]) as $bad
+                     | "ok\t\(.workflow_runs | map(select(.id != $self)) | length)\t\($bad | length)\t\([$bad[] | .name // "<unnamed>"] | unique | join(", "))"
+                   else "unusable" end' <<<"$runs_json" 2>/dev/null); then
+                IFS=$'\t' read -r probe_marker probe_runs probe_startup probe_broken <<<"$probe_out" || true
+                if [ "${probe_marker:-}" = "ok" ]; then
+                  probe=ok; runs_seen="$probe_runs"; startup_count="$probe_startup"; broken="$probe_broken"
+                fi
+              fi
+              if [ "$probe" != "ok" ]; then
+                echo "::warning::phase=ci-wait result=probe-unavailable ... attempt=$i/$max_attempts head=$EXPECTED_HEAD_SHA"
+                sleep 30
+                continue
+              fi
+              if [ "$startup_count" -gt 0 ]; then
+                echo "::error::phase=ci-wait result=startup-failure ... head=$EXPECTED_HEAD_SHA workflows=$broken"
+                echo "This run is permanent for $EXPECTED_HEAD_SHA — re-running the gate will not clear it. Fix the workflow, then push a new commit; alternatively delete the stale startup_failure run for this SHA."
+                exit 1
+              fi
+              # Absence of a check is NOT a passing check (#143). Decide promptly
+              # when nothing was ever triggered rather than burning the window.
+              if [ "$checks" -eq 0 ]; then
+                if [ "$runs_seen" -eq 0 ] && [ "$i" -ge "$no_checks_grace_attempts" ]; then
+                  if [ "${ALLOW_ABSENT_CHECKS:-false}" = "true" ]; then
+                    echo "::warning::phase=ci-wait result=no-checks-allowed ... head=$EXPECTED_HEAD_SHA"
+                    exit 0
+                  fi
+                  echo "::error::phase=ci-wait result=no-checks ... attempts=$i head=$EXPECTED_HEAD_SHA"
+                  echo "$no_checks_remediation"
+                  exit 1
+                fi
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
+            if [ "${ALLOW_ABSENT_CHECKS:-false}" = "true" ]; then
+              echo "::warning::phase=ci-wait result=no-checks-allowed ... head=$EXPECTED_HEAD_SHA"
+              exit 0
+            fi
+            echo "::error::phase=ci-wait result=no-checks elapsed_seconds=$elapsed lane=$LANE head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
           echo "::error::phase=ci-wait result=timeout elapsed_seconds=$elapsed lane=$LANE pending=$pending"
           exit 1
```

The merge recheck mirrors it, in the same order (probe → startup-failure →
no-checks) so both steps diagnose the same repo state identically, with a bounded
retry because the model review is already paid for at this point:

```diff
           if [ -n "$pending" ]; then
             echo "::error::phase=merge-recheck result=pending ... pending=$pending"
             exit 1
           fi
+          broken=""
+          startup_count=0
+          probe=unavailable
+          for probe_attempt in 1 2 3; do
+            if runs_json=$(gh api "repos/$REPO/actions/runs?head_sha=$EXPECTED_HEAD_SHA&per_page=100" 2>/dev/null) &&
+               probe_out=$(jq -r '
+                 ((env.GITHUB_RUN_ID // "") | tonumber? // -1) as $self
+                 | if (has("workflow_runs") and (.workflow_runs | type == "array")) then
+                   ([.workflow_runs[]
+                     | select(((.conclusion // "") | ascii_downcase) == "startup_failure")]) as $bad
+                   | "ok\t\(.workflow_runs | map(select(.id != $self)) | length)\t\($bad | length)\t\([$bad[] | .name // "<unnamed>"] | unique | join(", "))"
+                 else "unusable" end' <<<"$runs_json" 2>/dev/null) &&
+               IFS=$'\t' read -r probe_marker _ probe_startup probe_broken <<<"$probe_out" &&
+               [ "${probe_marker:-}" = "ok" ]; then
+              probe=ok; startup_count="$probe_startup"; broken="$probe_broken"; break
+            fi
+            echo "::warning::phase=merge-recheck result=probe-retry attempt=$probe_attempt/3 head=$EXPECTED_HEAD_SHA"
+            if [ "$probe_attempt" -lt 3 ]; then sleep 5; fi
+          done
+          if [ "$probe" != "ok" ]; then
+            echo "::error::phase=merge-recheck result=probe-unavailable ... head=$EXPECTED_HEAD_SHA"
+            exit 1
+          fi
+          if [ "$startup_count" -gt 0 ]; then
+            echo "::error::phase=merge-recheck result=startup-failure ... workflows=$broken"
+            exit 1
+          fi
+          if [ "$(jq 'length' <<<"$rollup")" -eq 0 ]; then
+            if [ "${ALLOW_ABSENT_CHECKS:-false}" = "true" ]; then
+              echo "::warning::phase=merge-recheck result=no-checks-allowed ... head=$EXPECTED_HEAD_SHA"
+            else
+              echo "::error::phase=merge-recheck result=no-checks ... head=$EXPECTED_HEAD_SHA"
+              exit 1
+            fi
+          fi
           if [ "$LANE" = "fast" ]; then
```

The opt-out is an input on both public surfaces, default strict:

```diff
   workflow_call:
     inputs:
+      allow_absent_checks:
+        description: Proceed even though the PR has NO CI checks at all. Defaults
+          to false (strict); absent checks are treated as not-green (#143).
+        required: false
+        type: boolean
+        default: false
```

Full change: https://github.com/Verjson/.github/pull/145
