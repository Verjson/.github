#!/usr/bin/env bash
# Break merge-gate poll deadlocks on the shared self-hosted fleet.
#
# `gate` (ai-review-merge.yml) and `privileged_merge` (ai-privileged-merge.yml)
# hold a runner for tens of minutes while POLLING for checks they cannot
# influence. On a fixed pool that is a resource deadlock, not slowness: on
# 2026-08-03 six gate jobs held all six runners while waiting for CI that could
# not start, because the CI needed the runners the gates were holding.
# Throughput was zero until they were cancelled by hand.
#
# ADR 0048 removed this for PUBLIC targets by routing them to elastic hosted
# capacity, but 88 of 90 repositories in this organization are private and stay
# on the fixed pool, so the deadlock is still reachable for almost all of them.
# Until the gate stops occupying a runner while it waits, something has to break
# the tie. This does, on the same rule a human would apply.
#
# Deliberately conservative. It cancels a run ONLY when every one of these holds:
#
#   1. The job is a known poll job (`gate` / `privileged_merge`) — never CI,
#      never a build, never anything whose work would be lost.
#   2. It is PROVABLY still polling. Where a workflow names the step that does
#      the polling, that step's own state answers the question directly, so a
#      gate that is 20 minutes into its poll is reachable and a gate that has
#      left `ci_wait` for the model review is not, at any age (#343). Only a
#      workflow with no separable poll step falls back to MIN_AGE_MINUTES.
#   3. Self-hosted capacity is actually exhausted (no idle runner).
#   4. Something is actually queued behind it. With an empty queue a long poll
#      harms nobody and is left alone.
#
# Cancelling is safe and reversible: the merge is atomic and happens at the END
# of the poll, so a cancelled run has not half-merged anything, and the next
# push/label/dispatch re-fires the gate. The cost of a false positive is one
# re-run; the cost of a false negative is a frozen fleet.
#
# Disposition (ADR 0055, #341): retained rather than retired. ADR 0053's
# `VERJSON_RUNNER_OVERFLOW` moves `gate`/`dispatch-merge` off the pool, but it
# does NOT cover `ai-privileged-merge.yml` (which routes on
# `VERJSON_LANE_PRIVILEGED`), and it is explicitly a budget that will be given
# back. `privileged_merge` is both the residual exposure and the only thing this
# watchdog has ever preempted in production.
set -uo pipefail

ORG="${WATCHDOG_ORG:-Verjson}"
MIN_AGE_MINUTES="${WATCHDOG_MIN_AGE_MINUTES:-35}"
# Floor for the provable-poll path. A jam forms fully in ~12 minutes, so the age
# threshold that guards the inferred path is far too late here; this only exists
# so a job that has just entered its poll is not preempted before the runner it
# is holding could plausibly have mattered.
MIN_POLL_MINUTES="${WATCHDOG_MIN_POLL_MINUTES:-10}"
RUNNER_LABEL="${WATCHDOG_RUNNER_LABEL:-general}"

# Poll jobs, by the workflow `name:` that owns them. Matching on workflow name
# rather than job name keeps CI jobs out of scope even if a repository happens
# to name a job `gate`.
POLL_WORKFLOWS="${WATCHDOG_POLL_WORKFLOWS:-AI review + auto-merge|AI privileged merge}"

# `<workflow name>=<step name>` pairs, `|`-separated. A run whose named step is
# `in_progress` is provably sleeping on a check it cannot influence; once that
# step completes the job is spending model-review budget and must be left alone.
# `AI privileged merge` is deliberately absent: its poll loop lives inside the
# same step as the merge itself, so there is nothing to separate and it keeps
# the age rule, which is the rule that has actually fired in production.
POLL_STEPS="${WATCHDOG_POLL_STEPS:-AI review + auto-merge=Wait once for the rest of CI to be green}"

note() { printf '::notice::watchdog %s\n' "$1"; }
warn() { printf '::warning::watchdog %s\n' "$1"; }
die()  { printf '::error::watchdog %s\n' "$1" >&2; exit 2; }

# No implicit default. This process cancels other repositories' runs, and #336
# shipped armed because two layers each carried their own default and the
# running log described the other one. The arm/disarm decision lives in exactly
# one place now — the workflow's `WATCHDOG_DRY_RUN` expression — and anything
# this script cannot read as a decision is a fault, not a licence to cancel.
DRY_RUN="${WATCHDOG_DRY_RUN-}"
case "$DRY_RUN" in
  true | false) ;;
  '') die "WATCHDOG_DRY_RUN is unset — refusing to guess whether cancelling is authorised. Set it to 'true' (report only) or 'false' (cancel)." ;;
  *)  die "WATCHDOG_DRY_RUN must be exactly 'true' or 'false', got '$DRY_RUN' — refusing to cancel on an ambiguous switch." ;;
esac

now_epoch="$(date -u +%s)" || die "could not read the clock"

# The step that does the polling for a given workflow, or empty when the
# workflow has none and must fall back to the age rule.
#
# The feed is `printf '%s\n'`, not `printf '%s'`: `read` returns non-zero on a
# final line with no terminator, so a single unterminated entry never enters the
# loop body at all and every workflow silently falls back to the age rule this
# function exists to replace.
poll_step_for() {
  local wf="$1" entry
  while IFS= read -r entry; do
    case "$entry" in
      "$wf="*) printf '%s' "${entry#*=}"; return 0 ;;
    esac
  done < <(printf '%s\n' "$POLL_STEPS" | tr '|' '\n')
  return 0
}

# --- 1. Is self-hosted capacity actually exhausted? -------------------------
# An unreadable runner list is inconclusive, and inconclusive must not authorise
# cancelling anything — bail rather than guess.
runners="$(gh api "orgs/$ORG/actions/runners" --paginate 2>/dev/null)" \
  || die "could not read the runner list for $ORG — refusing to cancel on an unknown fleet state"

# `--paginate` emits one JSON document PER PAGE, so a `jq` filter applied to that
# stream produces one count per page. The moment the fleet outgrows a single page
# `idle` becomes something like "0\n1", the numeric guard below rejects it, and
# the watchdog disables itself (#355). Slurp the pages and aggregate `.runners`
# across all of them before counting anything. A page missing its `.runners`
# array is an unusable response, not an empty pool: fail closed, because an
# undercount of idle capacity is exactly what authorises cancelling.
pool="$(jq -s -c --arg pool "$RUNNER_LABEL" '
  if length == 0 or any(.[]; (.runners | type) != "array")
  then error("unusable runner list")
  else [ .[].runners[]
       | select(.status == "online")
       | select([.labels[]?.name] | index($pool)) ]
       | {total: length, idle: (map(select(.busy | not)) | length)}
  end' <<<"$runners" 2>/dev/null)" \
  || die "could not aggregate the runner list for $ORG — refusing to cancel on an unknown fleet state"

idle="$(jq -r '.idle' <<<"$pool" 2>/dev/null)"
total="$(jq -r '.total' <<<"$pool" 2>/dev/null)"
[[ "$idle" =~ ^[0-9]+$ ]] || die "could not count idle runners"
[[ "$total" =~ ^[0-9]+$ ]] || die "could not count online runners"

note "pool=$RUNNER_LABEL online=$total idle=$idle"
if [ "$idle" -gt 0 ]; then
  note "capacity available — nothing to break"
  exit 0
fi

# --- 2. Enumerate repositories once -----------------------------------------
repos="$(gh api "orgs/$ORG/repos" --paginate --jq '.[].name' 2>/dev/null)" \
  || die "could not list repositories for $ORG"

queued=0
declare -a candidates=()

while IFS= read -r repo; do
  [ -n "$repo" ] || continue

  # Anything queued in this repository counts as starved work.
  q="$(gh api "repos/$ORG/$repo/actions/runs?status=queued&per_page=100" 2>/dev/null \
        | jq -r '[.workflow_runs[]?] | length' 2>/dev/null)" || q=0
  [[ "$q" =~ ^[0-9]+$ ]] || q=0
  queued=$((queued + q))

  # ...and any poll job that is provably sleeping is a candidate to yield its
  # runner.
  while IFS=$'\t' read -r run_id wf_name; do
    [ -n "$run_id" ] || continue
    jobs_json="$(gh api "repos/$ORG/$repo/actions/runs/$run_id/jobs" 2>/dev/null)" || continue
    job="$(jq -c '[.jobs[]? | select(.status == "in_progress")] | first // empty' \
      <<<"$jobs_json" 2>/dev/null)"
    [ -n "$job" ] || continue
    started="$(jq -r '.started_at // empty' <<<"$job" 2>/dev/null)"
    [ -n "$started" ] || continue
    started_epoch="$(date -u -d "$started" +%s 2>/dev/null)" || continue
    age=$(( (now_epoch - started_epoch) / 60 ))

    # Age is a proxy for the wrong thing. A job is preemptable when it is
    # WAITING, not when it is old — and MIN_AGE_MINUTES is longer than the AI
    # lane's own 30-minute poll window, so on that lane it could only ever reach
    # jobs that had already stopped polling and started paying for model review
    # (#343). Where the workflow names its poll step, read that step's state
    # instead of guessing from the clock.
    poll_step="$(poll_step_for "$wf_name")"
    if [ -n "$poll_step" ]; then
      poll_state="$(jq -r --arg s "$poll_step" \
        '([.steps[]? | select(.name == $s)] | first | .status) // "absent"' \
        <<<"$job" 2>/dev/null)" || poll_state=absent
      # `completed` means the job is past `ci_wait` and into the review; `absent`
      # means it has not reached the poll yet, or the shape changed and we cannot
      # tell. Both are "leave it alone" — the fail-closed direction here is fewer
      # cancellations.
      [ "$poll_state" = in_progress ] || continue
      [ "$age" -ge "$MIN_POLL_MINUTES" ] || continue
    else
      [ "$age" -ge "$MIN_AGE_MINUTES" ] || continue
    fi
    candidates+=("$repo|$run_id|$age|$wf_name")
    # Exact membership, NOT a regex: the workflow is literally named
    # "AI review + auto-merge", and `+` is a quantifier — `test()` on that name
    # matches nothing, so a regex form silently finds zero candidates and the
    # watchdog quietly never fires.
    # `gh api --jq` takes a filter but NOT `--arg`, so fetch raw and let real jq
    # bind the name list. Exact membership, NOT a regex: the workflow is literally
    # named "AI review + auto-merge" and `+` is a quantifier, so `test()` on that
    # name matches nothing — a regex form silently finds zero candidates and the
    # watchdog quietly never fires.
  done < <(gh api "repos/$ORG/$repo/actions/runs?status=in_progress&per_page=50" 2>/dev/null \
             | jq -r --arg names "$POLL_WORKFLOWS" \
                 '.workflow_runs[]? | select(.name | IN($names | split("|")[])) | "\(.id)\t\(.name)"' 2>/dev/null)
done <<<"$repos"

note "queued_runs=$queued stale_poll_jobs=${#candidates[@]} min_age_minutes=$MIN_AGE_MINUTES min_poll_minutes=$MIN_POLL_MINUTES dry_run=$DRY_RUN"

# --- 3. Only intervene when something is actually starved -------------------
if [ "${#candidates[@]}" -eq 0 ]; then
  note "no poll job has been running long enough to preempt"
  exit 0
fi
if [ "$queued" -eq 0 ]; then
  note "pool is full but nothing is waiting — a long poll harms nobody, leaving it"
  exit 0
fi

# --- 4. Preempt ---------------------------------------------------------------
cancelled=0
for entry in "${candidates[@]}"; do
  IFS='|' read -r repo run_id age wf_name <<<"$entry"
  if [ "$DRY_RUN" = true ]; then
    note "DRY RUN would cancel $repo run=$run_id age=${age}m workflow='$wf_name'"
    cancelled=$((cancelled + 1))
    continue
  fi
  if gh api --method POST "repos/$ORG/$repo/actions/runs/$run_id/cancel" --silent 2>/dev/null; then
    warn "preempted $repo run=$run_id age=${age}m workflow='$wf_name' — it was holding a runner while polling, and $queued run(s) were queued behind it. It will re-fire on the next event, or dispatch it manually."
    cancelled=$((cancelled + 1))
  else
    note "could not cancel $repo run=$run_id (already finishing?)"
  fi
done

note "preempted=$cancelled of ${#candidates[@]} candidate(s)"
