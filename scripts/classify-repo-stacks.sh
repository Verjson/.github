#!/usr/bin/env bash
# Classify every repository by the reusable CI workflow it calls, and report
# whether its CALLER JOB NAME matches the core check contract (ADR 0058, step 1).
#
# Read-only. It writes no property and no ruleset.
#
# WHY THIS IS STATIC AND NOT SAMPLED
#
# `required-checks-audit.sh` answers "does this repository emit its core set?"
# by looking at merged PR heads. That is the right question once a repository
# has history, but it cannot answer the question that decides whether the
# contract is even satisfiable: a reusable call's check name is
# `<caller job> / <inner job>`, and the caller job name is chosen by the
# consumer. The org pins the right-hand side; nothing today pins the left.
#
# A repository calling `node-ci.yml` from a job named `build` emits
# `build / build-test`, not `ci / build-test`. Requiring the contract there
# leaves it permanently pending — the same wedge, arrived at from a direction
# no amount of PR sampling explains, because the sampled contexts all look
# perfectly healthy. They are simply named something else.
#
# So this reads the workflow files themselves. It needs no merge history, works
# on a repository that has never had a PR, and names the exact remediation:
# rename the caller job, or adopt the generated thin caller that pins it.
set -euo pipefail

fault() { echo "::error::phase=$1 result=$2 ${3:-}" >&2; exit 2; }

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 ||
    fault startup toolchain-missing "tool=$tool — install it or this cannot run."
done

ORG="${CRS_ORG:?CRS_ORG must name the organization}"

# The canonical caller job name per contract slot. These are the LEFT-hand side
# of the check context; the right-hand side is pinned by the reusable workflow.
CANONICAL_CI_JOB="${CRS_CI_JOB:-ci}"
CANONICAL_CHANGELOG_JOB="${CRS_CHANGELOG_JOB:-changelog}"

stack_for_workflow() { # $1 = reusable workflow filename
  case "$1" in
    node-ci.yml)   printf 'node' ;;
    ui-ci.yml)     printf 'ui' ;;
    helm-ci.yml)   printf 'helm' ;;
    pulumi-ci.yml) printf 'pulumi' ;;
    *) printf '' ;;
  esac
}

repos() {
  if [ -n "${CRS_REPOS:-}" ]; then
    printf '%s\n' $CRS_REPOS
  else
    gh api --paginate "orgs/$ORG/repos?per_page=100" --jq '.[] | select(.archived | not) | .name'
  fi
}

# List workflow file paths in a repository. A repository with no workflow
# directory is not an error — it is a `none` stack.
workflow_paths() { # $1 = repo
  gh api "repos/$ORG/$1/contents/.github/workflows" \
    --jq '.[]? | select(.type == "file") | select(.name | test("\\.ya?ml$")) | .path' 2>/dev/null || true
}

# Emit `<job-name>\t<reusable-filename>` for every reusable Verjson call in a
# workflow file. Deliberately a line-oriented scan rather than a YAML parse:
# the runner image is not guaranteed to carry a YAML tool, and the shape being
# matched (`  <job>:` at two-space indent, `uses:` naming a Verjson reusable
# workflow) is stable and already how this repository's other checks read
# workflow files.
calls_in_file() { # $1 = repo, $2 = path
  gh api "repos/$ORG/$1/contents/$2" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      job = $1; sub(/:$/, "", job)
      # Every job name is emitted once as a local definition, so a repository
      # that DEFINES a contract job rather than calling one is still visible.
      print "job\t" job
      next
    }
    /^[[:space:]]*uses:[[:space:]]*Verjson\/\.github\/\.github\/workflows\// {
      line = $0
      sub(/.*\/workflows\//, "", line)
      sub(/@.*$/, "", line)
      gsub(/[[:space:]"'"'"']/, "", line)
      if (job != "") print "uses\t" job "\t" line
    }'
}

conformant=0
nonconformant=0
needs_review=0

classify_repo() {
  local repo="$1" stack='' ci_job='' changelog_job='' findings=() path kind job wf
  local local_jobs=''

  while read -r path; do
    [ -n "$path" ] || continue
    while IFS=$'\t' read -r kind job wf; do
      if [ "$kind" = job ]; then
        local_jobs="$local_jobs$job"$'\n'
        continue
      fi
      [ -n "$wf" ] || continue
      local s; s="$(stack_for_workflow "$wf")"
      if [ -n "$s" ]; then
        # Two different stack workflows in one repository is not something the
        # contract can express — the repository needs a decision, not a guess.
        if [ -n "$stack" ] && [ "$stack" != "$s" ]; then
          findings+=("calls both $stack and $s CI; the contract has no combined stack")
        fi
        stack="$s"; ci_job="$job"
      elif [ "$wf" = "changelog-validate.yml" ]; then
        changelog_job="$job"
      fi
    done < <(calls_in_file "$repo" "$path")
  done < <(workflow_paths "$repo")

  # A repository can satisfy a stack by DEFINING its jobs locally instead of
  # calling a reusable workflow — which is how the org's own `.github`
  # repository works, since it is where those workflows live. Scanning only for
  # `uses:` classifies it `none`, and `none` requires nothing beyond `gate`, so
  # the one repository holding the merge gate would be the one repository whose
  # test suite was not a merge precondition. Locally-defined contract jobs count.
  if [ -z "$stack" ] && [ -n "$local_jobs" ]; then
    grep -Fxq 'shell-tests' <<<"$local_jobs" && stack='actions'
  fi

  # A repository calling no stack CI workflow is `none`: it is still required to
  # emit `gate`, which the required-workflow rule guarantees, and nothing else.
  [ -n "$stack" ] || stack='none'

  if [ -n "$ci_job" ] && [ "$ci_job" != "$CANONICAL_CI_JOB" ]; then
    findings+=("CI caller job is '$ci_job', so it emits '$ci_job / …' not '$CANONICAL_CI_JOB / …'")
  fi
  if [ -n "$changelog_job" ] && [ "$changelog_job" != "$CANONICAL_CHANGELOG_JOB" ]; then
    findings+=("changelog caller job is '$changelog_job', so it emits '$changelog_job / validate'")
  fi

  local pkg=no
  [ -n "$changelog_job" ] && pkg=yes

  # `none` means "calls no reusable CI and defines no contract job". That is
  # correct for a repository with no CI at all, and MISLEADING for one whose CI
  # is simply local and unrecognised: the contract would require only `gate`
  # there, so its real CI stops being a merge precondition. That under-requires
  # rather than wedges, so it is a warning and not an error — but it is a
  # silent safety regression if nobody looks, which is exactly the shape of
  # defect this migration must not introduce.
  local njobs=0
  [ -n "$local_jobs" ] && njobs=$(grep -c . <<<"$local_jobs")
  if [ "$stack" = none ] && [ "$njobs" -gt 0 ]; then
    echo "::warning::phase=classify repo=$repo stack=none package=$pkg local_jobs=$njobs result=unrecognised-ci — defines jobs but calls no reusable CI; requiring only 'gate' here would make its existing CI advisory. Confirm it has nothing that should block a merge."
    needs_review=$((needs_review + 1))
    return 0
  fi

  if [ "${#findings[@]}" -eq 0 ]; then
    echo "::notice::phase=classify repo=$repo stack=$stack package=$pkg result=conformant"
    conformant=$((conformant + 1))
  else
    local why; why="$(printf '%s; ' "${findings[@]}")"
    echo "::error::phase=classify repo=$repo stack=$stack package=$pkg result=nonconformant ${why}— requiring the contract here would leave it permanently pending. Adopt the generated thin caller, or rename the job."
    nonconformant=$((nonconformant + 1))
  fi
}

echo "::notice::phase=start org=$ORG mode=read-only ci_job=$CANONICAL_CI_JOB changelog_job=$CANONICAL_CHANGELOG_JOB"
while read -r repo; do
  [ -n "$repo" ] || continue
  classify_repo "$repo"
done < <(repos)
echo "::notice::phase=done conformant=$conformant nonconformant=$nonconformant needs_review=$needs_review"
[ "$nonconformant" -eq 0 ]
