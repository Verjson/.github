#!/usr/bin/env bash
# Run the changelog contract this repository publishes against this repository's
# own pull request (Verjson/.github#1425).
#
# The hub carries `verjson-stack=actions` and `verjson-core-checks=enforced`, so
# it is in the `core-checks-actions` ruleset cohort and NOT in
# `changelog-contract-required`: the `changelog / validate` required check that
# ~90 adopters run never ran here. #1418 merged a fragment with no `impact:`
# because of that, and the `CHANGELOG/<version>.md` snapshot it would have been
# consumed into is immutable.
#
# The hub is the contract's producer, so it exercises the contract at its SOURCE
# — `scripts/changelog.py` from this checkout — rather than adopting its own
# consumer packaging. That is deliberate: a cohort property is a claim about a
# repository's stack, and this keeps working if those properties are
# reorganized.
#
# `check-pr` is a different, narrower gate and is not a substitute: it covers the
# dependency-manifest/fragment pairing and exits 0 both for a missing `impact:`
# and for a duplicate fragment identity. Only `validate --base` sees either.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
engine="$here/../changelog.py"
repo_root="$(cd "${1:-$here/../..}" && pwd)"

die() {
  printf 'hub-changelog-validate: %s\n' "$1" >&2
  exit 1
}

git_repo() { git -C "$repo_root" "$@"; }

# `GITHUB_BASE_REF` is the branch a pull request targets, which is what the
# generated consumer caller reads from the pull-request event. Outside a pull
# request — a push to main, or a local run — `main` is the only base there is.
base_branch="${GITHUB_BASE_REF:-main}"
base="origin/$base_branch"

fetch_base_branch() {
  git_repo fetch --no-tags --quiet origin \
    "+refs/heads/$base_branch:refs/remotes/origin/$base_branch"
}

# actions-ci checks out with `fetch-depth: 1`, so neither the base ref nor any
# common ancestor is present. Deepening is therefore the normal path here, not an
# error path. `--unshallow` rather than a fixed `--deepen=<n>`: the distance from
# HEAD to the merge base is the pull request's length, and a gate that guessed it
# would pass vacuously on exactly the large pull requests that most need it.
if git_repo rev-parse --is-shallow-repository | grep '^true$' >/dev/null; then
  git_repo fetch --no-tags --quiet --unshallow origin \
    || die "cannot deepen the shallow checkout from origin to reach $base"
fi

git_repo rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || fetch_base_branch \
  || die "cannot resolve the base revision $base from origin"

git_repo rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || die "cannot resolve the base revision $base even after fetching it"

# A base with no common ancestor would make the contract diff nothing and report
# success, which is the failure mode this gate exists to remove. Say so instead.
git_repo merge-base "$base" HEAD >/dev/null 2>&1 \
  || die "$base and HEAD share no common ancestor, so the contract would validate an empty diff"

exec python3 "$engine" validate \
  --repo-root "$repo_root" --base "$base" --head HEAD
