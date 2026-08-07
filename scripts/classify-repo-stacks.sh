#!/usr/bin/env bash
# Classify every repository by the reusable CI workflow it calls, and report
# whether its CALLER JOB SHAPE can emit the core check contract (ADR 0058,
# step 1): canonical name and no strategy matrix.
#
# Read-only. It writes no property and no ruleset.
#
# WHY THIS IS STATIC AND NOT SAMPLED
#
# `required-checks-audit.sh` answers "does this repository emit its core set?"
# by looking at merged PR heads. That is the right question once a repository
# has history, but it cannot answer the question that decides whether the
# contract is even satisfiable: a reusable call's check name is
# `<caller job> / <inner job>` only for an unmatrixed call. A matrix changes it
# to `<caller job> (<matrix values>) / <inner job>`. The caller controls both
# the left-hand name and whether GitHub inserts that matrix suffix.
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
      strategy_job = ""
      # Every job name is emitted once as a local definition, so a repository
      # that DEFINES a contract job rather than calling one is still visible.
      print "job\t" job
      next
    }
    /^    strategy:/ {
      strategy_job = job
      if ($0 ~ /[{,][[:space:]]*matrix[[:space:]]*:/ && job != "")
        print "matrix\t" job
      next
    }
    /^      matrix[[:space:]]*:/ {
      if (job != "" && strategy_job == job) print "matrix\t" job
      next
    }
    /^[[:space:]]*uses:[[:space:]]*Verjson\/\.github\/\.github\/workflows\// {
      line = $0
      sub(/.*\/workflows\//, "", line)
      sub(/@.*$/, "", line)
      gsub(/[[:space:]"'"'"']/, "", line)
      if (job != "") print "uses\t" job "\t" line
    }
    # `generated-artifacts.yml` runs the changelog contract only when asked to
    # (ADR 0055 enumerates its checks as boolean inputs), so the `uses:` line
    # alone does not put a repository on the changelog contract — a caller
    # passing only `adr-index: true` is not a package. The input is what counts,
    # and it appears after the `uses:` line, so it is emitted separately and
    # reconciled once the whole file has been read.
    /^[[:space:]]+changelog:[[:space:]]*true[[:space:]]*$/ {
      if (job != "") print "changelog-input\t" job
    }'
}

conformant=0
nonconformant=0
needs_review=0

classify_repo() {
  local repo="$1" stack='' ci_job='' changelog_job='' findings=() path kind job wf
  local local_jobs='' artifact_jobs='' changelog_inputs='' matrix_jobs=''

  while read -r path; do
    [ -n "$path" ] || continue
    while IFS=$'\t' read -r kind job wf; do
      if [ "$kind" = job ]; then
        local_jobs="$local_jobs$job"$'\n'
        continue
      fi
      if [ "$kind" = changelog-input ]; then
        changelog_inputs="$changelog_inputs$job"$'\n'
        continue
      fi
      if [ "$kind" = matrix ]; then
        matrix_jobs="$matrix_jobs$job"$'\n'
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
      elif [ "$wf" = "generated-artifacts.yml" ]; then
        artifact_jobs="$artifact_jobs$job"$'\n'
      fi
    done < <(calls_in_file "$repo" "$path")
  done < <(workflow_paths "$repo")

  # A `generated-artifacts.yml` caller is on the changelog contract only if it
  # actually asked for the changelog check. Resolved here rather than inline
  # because `with:` follows `uses:`, so the input is not yet known when the call
  # is seen. Without this the hardened path (ADR 0055, and the migration target
  # for #412) classifies `package=no`, and the audit quietly stops requiring
  # `changelog / validate` of the repositories that adopted it (#422).
  if [ -z "$changelog_job" ] && [ -n "$artifact_jobs" ]; then
    while read -r candidate; do
      [ -n "$candidate" ] || continue
      if grep -Fxq "$candidate" <<<"$changelog_inputs"; then
        changelog_job="$candidate"
        break
      fi
    done <<<"$artifact_jobs"
  fi

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
  if [ -n "$ci_job" ] && grep -Fxq "$ci_job" <<<"$matrix_jobs"; then
    findings+=("matrixed CI caller job '$ci_job' emits '$ci_job (<matrix>) / …', so canonical unmatrixed contexts never report")
  fi
  if [ -n "$changelog_job" ] && [ "$changelog_job" != "$CANONICAL_CHANGELOG_JOB" ]; then
    findings+=("changelog caller job is '$changelog_job', so it emits '$changelog_job / validate'")
  fi
  if [ -n "$changelog_job" ] && grep -Fxq "$changelog_job" <<<"$matrix_jobs"; then
    findings+=("matrixed changelog caller job '$changelog_job' emits '$changelog_job (<matrix>) / validate', so '$CANONICAL_CHANGELOG_JOB / validate' never reports")
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
    echo "::error::phase=classify repo=$repo stack=$stack package=$pkg result=nonconformant ${why}— requiring the contract here would leave it permanently pending. Adopt the generated thin caller, rename the job, or replace a matrixed reusable call with one unmatrixed caller job per supported variant."
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
