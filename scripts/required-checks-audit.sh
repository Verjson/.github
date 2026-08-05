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

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 ||
    fault startup toolchain-missing "tool=$tool — install it or this cannot run."
done

ORG="${RCA_ORG:?RCA_ORG must name the organization}"

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
CORE_UNIVERSAL="gate"
# Every PACKAGE repository, per ADR 0038's direction of travel. A repository not
# yet wired to the changelog contract emits nothing here — that is the finding
# this audit exists to surface, not a reason to soften the contract.
CORE_PACKAGE="changelog / validate"

core_contract_for() { # $1 = stack
  printf '%s\n' "$CORE_UNIVERSAL"
  case "$1" in
    node)    printf '%s\n' "ci / build-test" "ci / eligibility" "$CORE_PACKAGE" ;;
    ui)      printf '%s\n' "ci / build-test" "$CORE_PACKAGE" ;;
    helm)    printf '%s\n' "ci / lint-template" "$CORE_PACKAGE" ;;
    pulumi)  printf '%s\n' "ci / validate" "ci / preview" ;;
    actions) printf '%s\n' "shell-tests" ;;
    none)    ;;
    *) fault contract unknown-stack "stack='$1' has no declared core contract; classify the repository or extend core_contract_for." ;;
  esac
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
        --jq '.[] | select(.property_name == "verjson-stack") | .value' 2>/dev/null) || v=""
  printf '%s' "$v"
}

repos() {
  if [ -n "${RCA_REPOS:-}" ]; then
    printf '%s\n' $RCA_REPOS
  else
    gh api --paginate "orgs/$ORG/repos?per_page=100" --jq '.[] | select(.archived | not) | .name'
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

audit_repo() {
  local repo="$1" stack heads sha seen='' n=0 missing=() contract

  stack="$(stack_of "$repo")"
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

  heads=$(gh api "repos/$ORG/$repo/pulls?state=closed&per_page=$SAMPLE&sort=updated&direction=desc" \
    --jq '.[] | select(.merged_at != null) | .head.sha' 2>/dev/null) || {
    echo "::warning::phase=audit repo=$repo result=pulls-unreadable — not audited."
    return 0
  }

  while read -r sha; do
    [ -n "$sha" ] || continue
    local observed
    observed=$(contexts_for_head "$repo" "$sha") || {
      echo "::warning::phase=audit repo=$repo sha=$sha result=checks-unreadable — not audited."
      return 0
    }
    seen="$seen$observed"$'\n'
    n=$((n + 1))
  done <<<"$heads"

  if [ "$n" -eq 0 ]; then
    echo "::notice::phase=audit repo=$repo stack=$stack result=no-merged-prs — nothing to audit yet."
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
while read -r repo; do
  [ -n "$repo" ] || continue
  audit_repo "$repo"
done < <(repos)

echo "::notice::phase=done conformant=$conformant nonconformant=$nonconformant unclassified=$unclassified"
# Non-zero while any repository would be wedged, so this can gate step 3 in CI
# rather than being a report somebody remembers to read.
[ "$nonconformant" -eq 0 ] && [ "$unclassified" -eq 0 ]
