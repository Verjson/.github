#!/usr/bin/env bash
# Report which repositories do not yet emit their stack's CORE CHECK CONTRACT
# (ADR 0058, step 2). Read-only: it writes no ruleset and changes nothing.
#
# The contract is DECLARED here, not derived from what repositories happen to
# emit. Deriving it would make the current drift permanent — a stale repository's
# job naming would become organizational policy. The core set per stack lives in
# `core_contract_for`, and the check names it references are already pinned on
# the right-hand side by the org's reusable workflows (`node-ci` publishes
# `build-test` and `eligibility`, `helm-ci` publishes `lint-template`, and so
# on). The only free variable is the CALLER's job name, which is why the
# canonical caller names below are part of the contract and why generated thin
# callers, not convention, are what enforce them.
#
# WHY THIS EXISTS AS A SEPARATE, READ-ONLY STEP
#
# A required context that a repository never produces is not a warning — it is
# permanently pending, and that repository can never merge again until an admin
# removes the rule. At `~ALL` scope that is every repository in the org. So the
# question "does every repository actually emit its core set?" must be answered
# and driven to zero BEFORE any rule is written, and answering it must itself be
# incapable of breaking anything.
#
# The distinction that makes a context safe to require:
#
#   - A conditional JOB (`if:` false) emits a check run with conclusion
#     `skipped`, which SATISFIES a required check. Safe.
#   - A `paths:`-filtered WORKFLOW that does not match emits NO check run at
#     all, which is permanently pending. Fatal.
#
# So this audit reports a context as missing only when it is absent from every
# sampled PR head. A context that is present-but-skipped is conformant, and
# reporting it as missing would send people to "fix" the one shape that is
# already correct.
set -euo pipefail

fault() { echo "::error::phase=$1 result=$2 ${3:-}" >&2; exit 2; }

for tool in gh jq base64 python3; do
  command -v "$tool" >/dev/null 2>&1 ||
    fault startup toolchain-missing "tool=$tool — install it or this cannot run."
done
python3 -c 'import yaml' >/dev/null 2>&1 ||
  fault startup toolchain-missing "tool=python3-pyyaml — install it or workflow triggers cannot be audited."

ORG="${RCA_ORG:?RCA_ORG must name the organization}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_FILE="${RCA_CONTRACT_FILE:-$script_dir/../.github/required-check-contract.json}"
jq -e '
  .schema_version == 1 and
  .mode == "plan-only" and
  .mutation_authorized == false and
  (.universal_contexts | type == "array" and length > 0) and
  (.stacks | type == "object") and
  (.caller_job_names.stack | type == "string") and
  (.caller_job_names.generated_artifacts | type == "string")
' "$CONTRACT_FILE" >/dev/null 2>&1 ||
  fault contract declaration-invalid "file=$CONTRACT_FILE"

# How many recent merged PRs to look at per repository. One PR proves a context
# CAN report, never that the repository emits it as a matter of course, so the
# audit needs more than one head before it will call a context present.
SAMPLE="${RCA_SAMPLE_PRS:-5}"
[[ "$SAMPLE" =~ ^[0-9]+$ ]] ||
  fault startup sample-unparseable "RCA_SAMPLE_PRS='${SAMPLE}' is not a number."
[ "$SAMPLE" -ge 1 ] ||
  fault startup sample-too-small "RCA_SAMPLE_PRS=${SAMPLE} samples nothing."

# --- the declared core contract ---------------------------------------------
# Universal tier. `gate` is guaranteed everywhere by the existing `workflows`
# ruleset rule, which pins ai-review-merge.yml@main as a required workflow.
core_contract_for() { # $1 = stack
  jq -er --arg stack "$1" '
    if .stacks[$stack] == null then error("unknown stack")
    else .universal_contexts[], .stacks[$stack].contexts[]
    end
  ' "$CONTRACT_FILE" 2>/dev/null ||
    fault contract unknown-stack "stack='$1' has no declared core contract; classify the repository or extend $CONTRACT_FILE."
}

# `dispatch-merge` and `privileged_merge` PERFORM the merge, so a merge that
# waits for them waits for itself. They are never part of any contract; listed
# here so that a future edit to core_contract_for cannot quietly add one.
is_merge_machinery() {
  case "${1##*/ }" in
    dispatch-merge|privileged_merge) return 0 ;;
    *) return 1 ;;
  esac
}

# Stack classification comes from the org custom property `verjson-stack`.
# An unclassified repository is reported, never guessed: guessing is how a
# repository ends up required to emit a context its stack never produces.
stack_of() { # $1 = repo
  local v
  v=$(gh api "repos/$ORG/$1/properties/values" \
        --jq '.[] | select(.property_name == "verjson-stack") | .value' 2>/dev/null) ||
    return 1
  printf '%s' "$v"
}

repos() {
  if [ -n "${RCA_REPOS:-}" ]; then
    # shellcheck disable=SC2086  # Intentional whitespace-separated test override.
    printf '%s\n' $RCA_REPOS
  else
    gh api --paginate "orgs/$ORG/repos?per_page=100" --jq '.[] | select(.archived | not) | .name'
  fi
}

stack_workflow_for() {
  local value
  value="$(jq -er --arg stack "$1" '.stacks[$stack].reusable_workflow // empty' "$CONTRACT_FILE" 2>/dev/null)" ||
    return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

workflow_path_filter_state() {
  python3 -c '
import sys, yaml
doc = yaml.load(sys.stdin, Loader=yaml.BaseLoader)
events = doc.get("on", {}) if isinstance(doc, dict) else {}
if not isinstance(events, dict):
    print("false")
else:
    print("true" if any(
        isinstance(config, dict) and ("paths" in config or "paths-ignore" in config)
        for config in events.values()
    ) else "false")
'
}

caller_job_for() { # stdin = workflow source, $1 = reusable workflow filename
  awk -v target="/.github/workflows/$1@" '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]#]/ { in_jobs = 0 }
    in_jobs && /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
      job = $0
      sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
    }
    in_jobs && index($0, target) { print job }
  '
}

source_contract_for_repo() { # $1 = repo, $2 = stack
  local repo="$1" stack="$2" listing paths path source stack_workflow
  local stack_job='' generated_artifacts_job='' source_fault=0

  case "$stack" in
    actions|none) return 0 ;;
  esac
  stack_workflow="$(stack_workflow_for "$stack")" || return 2
  listing="$(gh api "repos/$ORG/$repo/contents/.github/workflows" 2>/dev/null)" ||
    return 2
  jq -e 'type == "array"' <<<"$listing" >/dev/null 2>&1 || return 2
  paths="$(jq -r '.[] | select(.type == "file") | .path' <<<"$listing")" ||
    return 2

  while read -r path; do
    [ -n "$path" ] || continue
    source="$(gh api "repos/$ORG/$repo/contents/$path" --jq .content 2>/dev/null |
      tr -d '\n' | base64 --decode 2>/dev/null)" || {
      source_fault=1
      break
    }

    local found path_filter
    path_filter="$(workflow_path_filter_state <<<"$source")" || {
      source_fault=1
      break
    }
    found="$(caller_job_for "$stack_workflow" <<<"$source")"
    if [ -n "$found" ]; then
      stack_job="$found"
      if [ "$path_filter" = true ]; then
        echo "::error::phase=audit repo=$repo stack=$stack result=workflow-path-filter path=$path — a required context can be absent permanently."
        return 1
      fi
    fi

    if [ "$stack" = node ] || [ "$stack" = ui ] || [ "$stack" = helm ]; then
      found="$(
        {
          caller_job_for generated-artifacts.yml <<<"$source"
          caller_job_for changelog-validate.yml <<<"$source"
        } | sed '/^$/d' | sort -u
      )"
      if [ -n "$found" ]; then
        generated_artifacts_job="$found"
        if [ "$path_filter" = true ]; then
          echo "::error::phase=audit repo=$repo stack=$stack result=workflow-path-filter path=$path — generated-artifacts / validate can be absent permanently."
          return 1
        fi
      fi
    fi
  done <<<"$paths"

  [ "$source_fault" -eq 0 ] || return 2
  if [ -z "$stack_job" ]; then
    echo "::error::phase=audit repo=$repo stack=$stack result=stack-caller-missing expected='ci / ${stack_workflow%.yml}'"
    return 1
  fi
  local expected_stack_job expected_generated_artifacts_job
  expected_stack_job="$(jq -r '.caller_job_names.stack' "$CONTRACT_FILE")"
  expected_generated_artifacts_job="$(jq -r '.caller_job_names.generated_artifacts' "$CONTRACT_FILE")"
  if [ "$stack_job" != "$expected_stack_job" ]; then
    echo "::error::phase=audit repo=$repo stack=$stack result=caller-job-name expected=$expected_stack_job actual=$stack_job"
    return 1
  fi
  if { [ "$stack" = node ] || [ "$stack" = ui ] || [ "$stack" = helm ]; } &&
    [ "$generated_artifacts_job" != "$expected_generated_artifacts_job" ]; then
    echo "::error::phase=audit repo=$repo stack=$stack result=caller-job-name expected=$expected_generated_artifacts_job actual=${generated_artifacts_job:-missing}"
    return 1
  fi
}

# Contexts observed on one head. A `skipped` conclusion counts as OBSERVED —
# the check run exists and satisfies a required check. Only a context with no
# check run at all is missing.
contexts_for_head() { # $1 = repo, $2 = sha
  local checks statuses
  checks=$(gh api --paginate "repos/$ORG/$1/commits/$2/check-runs?per_page=100" 2>/dev/null |
    jq -s -c '[.[].check_runs[]? | .name]') || return 1
  statuses=$(gh api --paginate "repos/$ORG/$1/commits/$2/status?per_page=100" 2>/dev/null |
    jq -s -c '[.[].statuses[]? | .context]') || return 1
  jq -n --argjson a "$checks" --argjson b "$statuses" '($a + $b) | unique | .[]' -r
}

conformant=0
nonconformant=0
unclassified=0
unaudited=0

audit_repo() {
  local repo="$1" stack heads sha seen='' n=0 missing=() contract

  stack="$(stack_of "$repo")" || {
    echo "::warning::phase=audit repo=$repo result=properties-unreadable — not audited."
    unaudited=$((unaudited + 1))
    return 0
  }
  if [ -z "$stack" ]; then
    echo "::warning::phase=audit repo=$repo result=unclassified — no 'verjson-stack' property; cannot know its core contract."
    unclassified=$((unclassified + 1))
    return 0
  fi

  # Resolve the contract BEFORE sampling, and in a plain command substitution so
  # that an unknown stack's `exit 2` actually reaches this shell. Resolving it
  # inside `< <(...)` instead would send the fault to a subshell the loop never
  # inspects: the contract would arrive empty, nothing would be reported
  # missing, and a repository nobody has classified would be called CONFORMANT —
  # the one wrong answer this audit exists to prevent.
  contract="$(core_contract_for "$stack")" || exit 2

  local source_rc=0
  source_contract_for_repo "$repo" "$stack" || source_rc=$?
  if [ "$source_rc" -eq 2 ]; then
    echo "::warning::phase=audit repo=$repo result=workflow-source-unreadable — not audited."
    unaudited=$((unaudited + 1))
    return 0
  elif [ "$source_rc" -ne 0 ]; then
    nonconformant=$((nonconformant + 1))
    return 0
  fi

  heads=$(gh api "repos/$ORG/$repo/pulls?state=closed&per_page=$SAMPLE&sort=updated&direction=desc" \
    --jq '.[] | select(.merged_at != null) | .head.sha' 2>/dev/null) || {
    echo "::warning::phase=audit repo=$repo result=pulls-unreadable — not audited."
    unaudited=$((unaudited + 1))
    return 0
  }

  while read -r sha; do
    [ -n "$sha" ] || continue
    local observed
    observed=$(contexts_for_head "$repo" "$sha") || {
      echo "::warning::phase=audit repo=$repo sha=$sha result=checks-unreadable — not audited."
      unaudited=$((unaudited + 1))
      return 0
    }
    seen="$seen$observed"$'\n'
    n=$((n + 1))
  done <<<"$heads"

  if [ "$n" -eq 0 ]; then
    echo "::notice::phase=audit repo=$repo stack=$stack result=no-merged-prs — nothing to audit yet."
    unaudited=$((unaudited + 1))
    return 0
  fi

  local ctx
  while read -r ctx; do
    [ -n "$ctx" ] || continue
    if is_merge_machinery "$ctx"; then
      fault contract merge-machinery-in-contract "stack='$stack' lists '$ctx'; requiring a merge job deadlocks the merge."
    fi
    grep -Fxq "$ctx" <<<"$seen" || missing+=("$ctx")
  done <<<"$contract"

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "::notice::phase=audit repo=$repo stack=$stack result=conformant sampled=$n"
    conformant=$((conformant + 1))
  else
    # Emitted as an error because this is the exact condition that would wedge
    # the repository if the rule were written today.
    echo "::error::phase=audit repo=$repo stack=$stack result=missing-core-contexts sampled=$n missing=$(printf '%s; ' "${missing[@]}")— requiring these today would leave $repo permanently pending."
    nonconformant=$((nonconformant + 1))
  fi
}

echo "::notice::phase=start org=$ORG sample=$SAMPLE mode=read-only"
repo_list="$(repos)" ||
  fault repository-list unreadable "org=$ORG — pagination or rate-limit failure."
while read -r repo; do
  [ -n "$repo" ] || continue
  audit_repo "$repo"
done <<<"$repo_list"

echo "::notice::phase=done conformant=$conformant nonconformant=$nonconformant unclassified=$unclassified unaudited=$unaudited"
# Non-zero while any repository would be wedged, so this can gate step 3 in CI
# rather than being a report somebody remembers to read.
[ "$nonconformant" -eq 0 ] && [ "$unclassified" -eq 0 ] && [ "$unaudited" -eq 0 ]
