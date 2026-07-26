#!/usr/bin/env bash
# Behavioural tests for rework-classify.sh: category assignment (sensitivity
# order), AI-authorship detection from the Co-Authored-By trailer, and the
# rework-signal tiers. Fixture-driven, no network.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
classify="$here/rework-classify.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

field() { jq -r ".[0].$1" ; }
run() { printf '%s' "$1" | "$classify"; }

check() { # desc, input, jqpath, expected
  local got
  got="$(run "$2" | field "$3")"
  [ "$got" = "$4" ] && pass "$1" || fail "$1 (want $4, got $got)"
}

# --- change_category (sensitivity-first) ---
check "authz path -> auth"            '[{"number":1,"title":"feat: x","files":["src/authz/guard.ts"],"commit_messages":["feat: x"]}]' change_category auth
check "sql migration -> migration"    '[{"number":2,"title":"chore: db","files":["db/migrations/001.sql"],"commit_messages":[""]}]'   change_category migration
check "pulumi ts -> infra (beats app)" '[{"number":3,"title":"feat: infra","files":["infra/pulumi/index.ts"],"commit_messages":[""]}]' change_category infra
check "workflow-only -> ci"           '[{"number":4,"title":"ci: bump","files":[".github/workflows/x.yml"],"commit_messages":[""]}]'    change_category ci
check "docs-only -> docs"             '[{"number":5,"title":"docs: y","files":["docs/a.md","README.md"],"commit_messages":[""]}]'        change_category docs
check "code+workflow -> app (beats ci)" '[{"number":6,"title":"feat: z","files":["src/a.ts",".github/workflows/x.yml"],"commit_messages":[""]}]' change_category app
check "unknown -> other"              '[{"number":7,"title":"chore: x","files":["Makefile"],"commit_messages":[""]}]'                    change_category other

# --- ai_authored ---
check "Co-Authored-By Claude -> ai"   '[{"number":8,"title":"feat: q","files":["src/a.ts"],"commit_messages":["feat: q\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>"]}]' ai_authored true
check "no trailer -> not ai"          '[{"number":9,"title":"feat: q","files":["src/a.ts"],"commit_messages":["feat: q"]}]'              ai_authored false

# --- rework_signal tiers ---
check "revert marker -> revert"       '[{"number":10,"title":"revert: bad","files":["src/a.ts"],"commit_messages":["Revert \"x\"\n\nThis reverts commit abc123."]}]' rework_signal revert
check "fix + Fixes # -> explicit_fix_ref" '[{"number":11,"title":"fix: crash","body":"Fixes #12","files":["src/a.ts"],"commit_messages":["fix: crash"]}]' rework_signal explicit_fix_ref
check "bare fix -> fix_same_area"     '[{"number":12,"title":"fix: tidy","files":["src/a.ts"],"commit_messages":["fix: tidy"]}]'         rework_signal fix_same_area
check "feat -> no rework signal"      '[{"number":13,"title":"feat: new","files":["src/a.ts"],"commit_messages":["feat: new"]}]'        rework_signal null

# --- defaults for missing friction fields ---
check "missing friction defaults to 0" '[{"number":14,"title":"feat: x","files":["src/a.ts"],"commit_messages":[""]}]'                  review_rounds 0

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
