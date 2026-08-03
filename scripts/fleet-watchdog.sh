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
#   2. It has been running longer than MIN_AGE_MINUTES. Past that point its own
#      poll window is nearly exhausted, so it was about to fail anyway.
#   3. Self-hosted capacity is actually exhausted (no idle runner).
#   4. Something is actually queued behind it. With an empty queue a long poll
#      harms nobody and is left alone.
#
# Cancelling is safe and reversible: the merge is atomic and happens at the END
# of the poll, so a cancelled run has not half-merged anything, and the next
# push/label/dispatch re-fires the gate. The cost of a false positive is one
# re-run; the cost of a false negative is a frozen fleet.
set -uo pipefail

ORG="${WATCHDOG_ORG:-Verjson}"
MIN_AGE_MINUTES="${WATCHDOG_MIN_AGE_MINUTES:-35}"
RUNNER_LABEL="${WATCHDOG_RUNNER_LABEL:-general}"
DRY_RUN="${WATCHDOG_DRY_RUN:-false}"

# Poll jobs, by the workflow `name:` that owns them. Matching on workflow name
# rather than job name keeps CI jobs out of scope even if a repository happens
# to name a job `gate`.
POLL_WORKFLOWS="${WATCHDOG_POLL_WORKFLOWS:-AI review + auto-merge|AI privileged merge}"

note() { printf '::notice::watchdog %s\n' "$1"; }
warn() { printf '::warning::watchdog %s\n' "$1"; }
die()  { printf '::error::watchdog %s\n' "$1" >&2; exit 2; }

now_epoch="$(date -u +%s)" || die "could not read the clock"

# --- 1. Is self-hosted capacity actually exhausted? -------------------------
# An unreadable runner list is inconclusive, and inconclusive must not authorise
# cancelling anything — bail rather than guess.
runners="$(gh api "orgs/$ORG/actions/runners" --paginate 2>/dev/null)" \
  || die "could not read the runner list for $ORG — refusing to cancel on an unknown fleet state"

idle="$(jq --arg pool "$RUNNER_LABEL" '
  [ .runners[]? | select(.status == "online")
  | select([.labels[]?.name] | index($pool))
  | select(.busy | not) ] | length' <<<"$runners" 2>/dev/null)"
[[ "$idle" =~ ^[0-9]+$ ]] || die "could not count idle runners"

total="$(jq --arg pool "$RUNNER_LABEL" '
  [ .runners[]? | select(.status == "online")
  | select([.labels[]?.name] | index($pool)) ] | length' <<<"$runners" 2>/dev/null)"

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

  # ...and any long-running poll job is a candidate to yield its runner.
  while IFS=$'\t' read -r run_id wf_name; do
    [ -n "$run_id" ] || continue
    started="$(gh api "repos/$ORG/$repo/actions/runs/$run_id/jobs" \
      --jq '[.jobs[]? | select(.status == "in_progress") | .started_at] | first // empty' 2>/dev/null)"
    [ -n "$started" ] || continue
    started_epoch="$(date -u -d "$started" +%s 2>/dev/null)" || continue
    age=$(( (now_epoch - started_epoch) / 60 ))
    [ "$age" -ge "$MIN_AGE_MINUTES" ] || continue
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

note "queued_runs=$queued stale_poll_jobs=${#candidates[@]} min_age_minutes=$MIN_AGE_MINUTES"

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
