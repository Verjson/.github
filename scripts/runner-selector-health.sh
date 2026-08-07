#!/usr/bin/env bash
# Report queued jobs that no online, repository-admitted org runner can accept.
# Exit 0 is proven satisfiable, 1 is selector drift, and 2 is undetermined.
set -uo pipefail

ORG="${ORG:-Verjson}"
NOW_EPOCH="${NOW_EPOCH:-}"
MAX_FUTURE_SKEW_SECONDS="${MAX_FUTURE_SKEW_SECONDS:-300}"

undetermined() {
  printf 'UNDETERMINED: %s\n' "$1" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || undetermined "gh is not available"
command -v jq >/dev/null 2>&1 || undetermined "jq is not available"
{ [ -z "$NOW_EPOCH" ] || [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]]; } \
  || undetermined "NOW_EPOCH is not an epoch"
[[ "$MAX_FUTURE_SKEW_SECONDS" =~ ^[0-9]+$ ]] \
  || undetermined "MAX_FUTURE_SKEW_SECONDS is not a non-negative integer"

fetch_pages() {
  local path="$1" page_shape="$2" out
  if ! out="$(gh api --paginate "$path" 2>&1)"; then
    printf 'UNDETERMINED: GET %s failed: %s\n' \
      "$path" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')" >&2
    return 2
  fi
  jq -e -s "length > 0 and all(.[]; $page_shape)" <<<"$out" >/dev/null 2>&1 \
    || { printf 'UNDETERMINED: GET %s returned incomplete or malformed pagination\n' "$path" >&2; return 2; }
  printf '%s\n' "$out"
}

repos_pages="$(fetch_pages "orgs/$ORG/repos?per_page=100" 'type == "array"')" || exit 2
repos="$(jq -sc '[.[][] | select(.archived == false)
  | {full_name, private}]' <<<"$repos_pages")" \
  || undetermined "could not aggregate repositories for $ORG"
jq -e 'length > 0 and all(.[]; (.full_name | type) == "string"
  and (.private | type) == "boolean")' <<<"$repos" >/dev/null \
  || undetermined "repository listing for $ORG is empty or malformed"

groups_pages="$(fetch_pages "orgs/$ORG/actions/runner-groups?per_page=100" \
  '(.runner_groups | type) == "array"')" || exit 2
groups="$(jq -sc '[.[].runner_groups[]]' <<<"$groups_pages")" \
  || undetermined "could not aggregate runner groups for $ORG"
jq -e 'length > 0 and all(.[];
  (.id | type) == "number"
  and (.name | type) == "string"
  and (.default | type) == "boolean"
  and (.visibility == "all" or .visibility == "selected")
  and (.allows_public_repositories | type) == "boolean")' <<<"$groups" >/dev/null \
  || undetermined "runner-group listing for $ORG is empty or malformed"
[ "$(jq '[.[] | select(.default == true)] | length' <<<"$groups")" -eq 1 ] \
  || undetermined "expected exactly one default runner group"

catalog='[]'
while IFS= read -r group; do
  group_id="$(jq -er '.id' <<<"$group")" || undetermined "runner group has no id"
  visibility="$(jq -er '.visibility' <<<"$group")" || undetermined "runner group $group_id has no visibility"

  runner_pages="$(fetch_pages \
    "orgs/$ORG/actions/runner-groups/$group_id/runners?per_page=100" \
    '(.runners | type) == "array"')" || exit 2
  runners="$(jq -sc '[.[].runners[]]' <<<"$runner_pages")" \
    || undetermined "could not aggregate runners for group $group_id"
  jq -e 'all(.[];
    (.status == "online" or .status == "offline")
    and (.busy | type) == "boolean"
    and (.labels | type) == "array"
    and all(.labels[]; (.name | type) == "string"))' <<<"$runners" >/dev/null \
    || undetermined "runner data for group $group_id is malformed"

  members='[]'
  if [ "$visibility" = selected ]; then
    member_pages="$(fetch_pages \
      "orgs/$ORG/actions/runner-groups/$group_id/repositories?per_page=100" \
      '(.repositories | type) == "array"')" || exit 2
    members="$(jq -sc '[.[].repositories[].full_name]' <<<"$member_pages")" \
      || undetermined "could not aggregate repositories for group $group_id"
    jq -e 'all(.[]; type == "string")' <<<"$members" >/dev/null \
      || undetermined "repository admission for group $group_id is malformed"
  fi

  catalog="$(jq -c --argjson group "$group" --argjson runners "$runners" \
    --argjson members "$members" \
    '. + [$group + {runners:$runners, members:$members}]' <<<"$catalog")" \
    || undetermined "could not build runner-group catalog"
done < <(jq -c '.[]' <<<"$groups")

issues=0
while IFS=$'\t' read -r repo private; do
  [ -n "$repo" ] || continue
  repo_name="${repo#"$ORG/"}"
  runs='[]'
  # A run becomes in_progress as soon as any job starts, while another job in
  # that same run can remain queued forever on an impossible selector.
  for run_status in queued in_progress; do
    runs_pages="$(fetch_pages \
      "repos/$ORG/$repo_name/actions/runs?status=$run_status&per_page=100" \
      '(.workflow_runs | type) == "array"')" || exit 2
    runs="$(jq -c --argjson pages "$(jq -sc '[.[].workflow_runs[]]' <<<"$runs_pages")" \
      '. + $pages | unique_by(.id)' <<<"$runs")" \
      || undetermined "could not aggregate $run_status runs for $repo"
  done

  while IFS= read -r run; do
    run_id="$(jq -er '.id' <<<"$run")" || undetermined "queued run in $repo has no id"
    run_created="$(jq -er '.created_at' <<<"$run")" \
      || undetermined "queued run $repo/$run_id has no created_at"
    created_epoch="$(date -u -d "$run_created" +%s 2>/dev/null)" \
      || undetermined "queued run $repo/$run_id has invalid created_at"
    current_epoch="${NOW_EPOCH:-$(date -u +%s)}"
    age_seconds=$((current_epoch - created_epoch))
    [ "$age_seconds" -ge "-$MAX_FUTURE_SKEW_SECONDS" ] \
      || undetermined "queued run $repo/$run_id is dated beyond the allowed clock skew"
    [ "$age_seconds" -ge 0 ] || age_seconds=0
    age_minutes=$((age_seconds / 60))

    jobs_pages="$(fetch_pages \
      "repos/$ORG/$repo_name/actions/runs/$run_id/jobs?per_page=100" \
      '(.jobs | type) == "array"')" || exit 2
    jobs="$(jq -sc '[.[].jobs[] | select(.status == "queued")]' <<<"$jobs_pages")" \
      || undetermined "could not aggregate queued jobs for $repo/$run_id"

    while IFS= read -r job; do
      job_id="$(jq -er '.id' <<<"$job")" || undetermined "queued job in $repo/$run_id has no id"
      job_name="$(jq -er '.name' <<<"$job")" || undetermined "queued job $job_id has no name"
      labels="$(jq -c '.labels' <<<"$job")" || undetermined "queued job $job_id has no labels"
      jq -e 'type == "array" and length > 0 and all(.[]; type == "string")' \
        <<<"$labels" >/dev/null || undetermined "queued job $job_id has malformed labels"

      # GitHub-hosted capacity is not visible in the organization runner APIs.
      # Only selectors explicitly requesting self-hosted capacity are decidable here.
      jq -e 'index("self-hosted") != null' <<<"$labels" >/dev/null || continue

      outcome="$(jq -r --arg repo "$repo" --argjson private "$private" \
        --argjson required "$labels" '
        def compatible($runner):
          [$runner.labels[].name] as $have
          | all($required[]; . as $required_label
            | ($have | index($required_label)) != null);
        def admitted($group):
          (($group.visibility == "all")
            or ($group.visibility == "selected"
              and ($group.members | index($repo)) != null))
          and ($private or $group.allows_public_repositories);
        [ .[] as $group
          | $group.runners[]
          | select(compatible(.))
          | {runner:., group:$group} ] as $matching
        | if any($matching[];
            .runner.status == "online" and admitted(.group))
          then "satisfiable"
          elif any($matching[];
            .runner.status == "online" and (admitted(.group) | not))
          then "runner-group-admission"
          else "labels/offline-capacity"
          end
      ' <<<"$catalog")" || undetermined "could not evaluate selector for $repo/$run_id/$job_id"

      [ "$outcome" = satisfiable ] && continue
      issues=$((issues + 1))
      printf 'UNSATISFIABLE: %s run=%s job=%s name=%q labels=%s age_minutes=%s cause=%s\n' \
        "$repo" "$run_id" "$job_id" "$job_name" "$labels" "$age_minutes" "$outcome" >&2
    done < <(jq -c '.[]' <<<"$jobs")
  done < <(jq -c '.[]' <<<"$runs")
done < <(jq -r '.[] | [.full_name, (.private | tostring)] | @tsv' <<<"$repos")

if [ "$issues" -gt 0 ]; then
  printf 'runner-selector-health: found %s queued job(s) with no compatible online admitted runner\n' \
    "$issues" >&2
  exit 1
fi

printf 'runner-selector-health: all queued self-hosted jobs are satisfiable\n'
