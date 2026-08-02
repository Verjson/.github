#!/usr/bin/env bash
# Contract check: every file a repository-wide scanner reads must be matched by
# an `actions-ci` path trigger (Verjson/.github#305).
#
# `doc-tag-pins.sh` reads every tracked file and `doc-fragment-names.sh` every
# tracked `*.md`, but the trigger is an enumeration. A surface a scanner reads
# and the trigger omits produces the worst failure shape available: the PR that
# introduces the bad example passes, and the next unrelated PR to touch a
# triggering path fails instead — pointing at the wrong change and the wrong
# author. Widening the trigger once fixes today; asserting the two agree is what
# stops them drifting apart again.
#
# Test seam: TRIGGER_SCOPE_ROOT selects the repository to check.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${TRIGGER_SCOPE_ROOT:-$(cd "$here/.." && pwd)}"
workflow="$root/.github/workflows/actions-ci.yml"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$workflow" ] || { echo "FAIL - workflow not found: $workflow"; exit 1; }

# The `paths:` list of the pull_request trigger, as written. Read from the
# workflow rather than restated here — a copy would let the two drift, which is
# the defect this file exists to prevent.
mapfile -t globs < <(
  awk '
    /^  pull_request:/ { in_pr = 1; next }
    in_pr && /^    paths:/ { in_paths = 1; next }
    in_paths && /^      - / {
      line = $0
      sub(/^      - /, "", line)
      gsub(/^['"'"'"]|['"'"'"]$/, "", line)
      print line
      next
    }
    in_paths && /^[^ ]/ { exit }
    in_paths && /^  [^ ]/ { exit }
  ' "$workflow"
)

[ "${#globs[@]}" -gt 0 ] \
  && pass "the pull_request path triggers were read from the workflow" \
  || fail "could not read any path trigger — the rest of this file would pass vacuously"

# Translate the glob forms GitHub accepts and this workflow uses into a test.
# Deliberately narrow: an unrecognised form is a hard error, not a silent
# "matches nothing", because that would quietly weaken every assertion below.
matches_any() { # matches_any <path>
  local path="$1" glob
  for glob in "${globs[@]}"; do
    case "$glob" in
      '**/*.'*)  [ "${path##*.}" = "${glob##*.}" ] && return 0 ;;
      *'/**')    [ "${path#"${glob%/**}"/}" != "$path" ] && return 0 ;;
      *'**'*)    echo "unhandled glob form: $glob" >&2; return 2 ;;
      *)         [ "$path" = "$glob" ] && return 0 ;;
    esac
  done
  return 1
}

# Every file each scanner actually reads, from the same command the scanner uses.
assert_scanner_covered() { # assert_scanner_covered <label> <ls-files args...>
  local label="$1"; shift
  local uncovered=0 checked=0 file rc
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    checked=$((checked + 1))
    matches_any "$file"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      fail "$label: a path trigger uses a glob form this check cannot evaluate"
      return
    fi
    if [ "$rc" -ne 0 ]; then
      printf '     uncovered: %s\n' "$file" >&2
      uncovered=$((uncovered + 1))
    fi
  done < <(git -C "$root" ls-files "$@")

  if [ "$checked" -eq 0 ]; then
    fail "$label: matched no tracked file, so this assertion proves nothing"
  elif [ "$uncovered" -eq 0 ]; then
    pass "$label: all $checked scanned file(s) are covered by a path trigger"
  else
    fail "$label: $uncovered of $checked scanned file(s) would not trigger their own PR"
  fi
}

assert_scanner_covered "doc-fragment-names.sh scans tracked *.md" '*.md'

# doc-tag-pins.sh reads every tracked file. Requiring a trigger for literally
# every path would mean running this suite on every PR, which is a cost the
# repository has already opened issues about (#233, #234). The honest contract is
# narrower and is asserted as such: every file that can carry a pin example — any
# markdown, and the workflow/action YAML where `uses:` lines live.
assert_scanner_covered "doc-tag-pins.sh scans documentation" '*.md'
assert_scanner_covered "doc-tag-pins.sh scans workflow definitions" '.github/workflows/*' '.github/actions/*'

# The two trigger lists must stay identical: a push-only gap means `main` can go
# red for a file whose PR never ran the check.
pr_block="$(awk '/^  pull_request:/,/^  push:/' "$workflow" | grep -c "^      - ")"
push_block="$(awk '/^  push:/,/^permissions:/' "$workflow" | grep -c "^      - ")"
[ "$pr_block" -eq "$push_block" ] && [ "$pr_block" -gt 0 ] \
  && pass "the pull_request and push triggers list the same number of paths" \
  || fail "trigger lists diverge: pull_request has $pr_block, push has $push_block"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
