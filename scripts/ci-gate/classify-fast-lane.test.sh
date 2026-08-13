#!/usr/bin/env bash
# Pins the non-agent documentation fast lane used by ai-review-merge.yml
# (Verjson/.github#66, #75, #767).
# The fast lane skips paid AI review for documentation/community-health-only PRs. When
# the changelog moved to NEXT/ fragments (#65), the allowlist still matched only the
# literal NEXT.md, so an "ADR + NEXT/ fragment" PR silently lost the free lane and paid
# for a full model review — a regression against the cost-reduction goal. The test
# drives the trusted classifier used by the workflow.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
classifier="$repo_root/scripts/ci-gate/classify-review-policy.py"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$classifier" ] || { echo "FAIL - classifier not found: $classifier"; exit 1; }

# eligible <filename...> -> exit 0 if that file set qualifies for the fast lane.
eligible() {
  local files; files="$(jq -n --args '[$ARGS.positional[] | {filename: ., status: "modified"}]' "$@")"
  python3 "$classifier" <<<"$files" | jq -e '.lane == "fast"' >/dev/null 2>&1
}

# --- Should be fast-lane eligible ---
eligible 'NEXT/2026-07-20-foo.md' \
  && pass "NEXT/ fragment is fast-lane eligible (#66 fix)" \
  || fail "NEXT/ fragment must be fast-lane eligible (#66 regression)"
eligible 'NEXT.md' \
  && pass "legacy NEXT.md stays eligible" || fail "legacy NEXT.md must stay eligible"
eligible 'docs/decisions/0016-x/README.md' \
  && pass "docs/** eligible" || fail "docs/** must be eligible"
eligible 'docs/decisions/0016-x/README.md' 'NEXT/2026-07-20-foo.md' \
  && pass "ADR + NEXT/ fragment PR eligible (the #66 case)" \
  || fail "ADR + NEXT/ fragment PR must be eligible (#66)"
eligible 'README.md' 'LICENSE' \
  && pass "community-health files eligible" || fail "community-health files must be eligible"

# --- Should NOT be eligible (one non-doc file drops the whole set) ---
eligible 'NEXT/2026-07-20-foo.md' 'src/app.js' \
  && fail "a code file must disqualify the fast lane" \
  || pass "a code file disqualifies the fast lane"
eligible 'NEXT/run.sh' \
  && fail "non-.md under NEXT/ must not be fast-laned" \
  || pass "non-.md under NEXT/ is not fast-laned"
eligible 'NEXT/subdir/2026-07-20-foo.md' \
  && fail "nested NEXT/ paths must not be fast-laned (#75)" \
  || pass "nested NEXT/ paths are not fast-laned (#75)"
eligible 'packages/widget/NEXT/2026-07-20-foo.md' \
  && fail "non-root NEXT/ paths must not be fast-laned (#75)" \
  || pass "non-root NEXT/ paths are not fast-laned (#75)"

if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; else echo "$fails test(s) failed."; exit 1; fi
