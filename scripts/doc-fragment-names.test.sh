#!/usr/bin/env bash
# Unit tests for scripts/doc-fragment-names.sh (Verjson/.github#305).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/doc-fragment-names.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

# fixture <name> [engine] -> path to a committed git repo whose docs carry $DOC.
# engine: real (default) copies the engine, absent omits it, blind ships one whose
# CANONICAL_NAME accepts everything.
fixture() {
  local name="$1" engine="${2:-real}"
  local doc_path="${3:-docs/guide.md}"
  local dir="$tmp/$name"
  mkdir -p "$dir/$(dirname "$doc_path")" "$dir/scripts"
  printf '%s\n' "$DOC" >"$dir/$doc_path"
  case "$engine" in
    real) cp "$repo_root/scripts/changelog.py" "$dir/scripts/changelog.py" ;;
    blind) printf 'import re\nCANONICAL_NAME = re.compile(r".*")\n' >"$dir/scripts/changelog.py" ;;
    absent) : ;;
  esac
  git init -q "$dir"
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.com
  git -C "$dir" add "$doc_path"
  [ "$engine" = absent ] || git -C "$dir" add scripts/changelog.py
  git -C "$dir" commit -qm fixture
  printf '%s\n' "$dir"
}

DOC='See `NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md` for the shape.'
good="$(fixture good)"
DOC_FRAGMENT_NAMES_ROOT="$good" bash "$script" >"$tmp/good.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "an example the engine accepts is accepted" \
  || { fail "canonical example rejected (rc=$rc)"; sed 's/^/diag - /' "$tmp/good.out"; }

spaced="$(fixture spaced real 'docs/release guide.md')"
DOC_FRAGMENT_NAMES_ROOT="$spaced" bash "$script" >"$tmp/spaced.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "a canonical example in a documentation path containing spaces is accepted"
else
  fail "space-containing documentation path corrupted the example (rc=$rc)"
  sed 's/^/diag - /' "$tmp/spaced.out"
fi

# The #305 regression: two independent readers inferred that the filename segment
# tracks the metadata key, so issue-less work was documented as `-id-`. The engine
# hardcodes `-issue-` and rejects that name.
DOC='See `NEXT/2026-07-30-id-20260730T184500Z-tidy-fixtures.md` for the shape.'
inferred="$(fixture inferred)"
DOC_FRAGMENT_NAMES_ROOT="$inferred" bash "$script" >"$tmp/inferred.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -q -- '-id-20260730T184500Z-' "$tmp/inferred.out"; } \
  && pass "an example the engine rejects is rejected and named (#305)" \
  || { fail "the -id- form was accepted or unreported (rc=$rc)"; sed 's/^/diag - /' "$tmp/inferred.out"; }

# A lookup that cannot reach the engine must read as "the check broke", never as a
# docs verdict — an engine that never answers otherwise reports zero rejections.
DOC='See `NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md` for the shape.'
engineless="$(fixture engineless absent)"
DOC_FRAGMENT_NAMES_ROOT="$engineless" bash "$script" >"$tmp/engineless.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'engine' "$tmp/engineless.out"; } \
  && pass "an engine the check cannot consult fails closed as a lookup fault" \
  || { fail "missing engine did not fail closed (rc=$rc)"; sed 's/^/diag - /' "$tmp/engineless.out"; }

# An engine that accepts everything answers every question with "fine", so the
# check would ratify any documentation. Only the real matcher is an oracle.
DOC='See `NEXT/2026-07-30-id-20260730T184500Z-tidy-fixtures.md` for the shape.'
blind="$(fixture blind blind)"
DOC_FRAGMENT_NAMES_ROOT="$blind" bash "$script" >"$tmp/blind.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an engine whose matcher accepts everything fails closed" \
  || { fail "a permissive stub engine was trusted as the oracle (rc=$rc)"; sed 's/^/diag - /' "$tmp/blind.out"; }

# A scanner that matches nothing agrees with every possible documentation. Zero
# examples means the scan stopped working, not that the docs are correct.
DOC='Fragment naming is described in the contract.'
exampleless="$(fixture exampleless)"
DOC_FRAGMENT_NAMES_ROOT="$exampleless" bash "$script" >"$tmp/exampleless.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'no fragment filename example' "$tmp/exampleless.out"; } \
  && pass "a scan that finds no example fails instead of passing vacuously" \
  || { fail "empty scan passed vacuously (rc=$rc)"; sed 's/^/diag - /' "$tmp/exampleless.out"; }

# Placeholder forms teach the shape and are not names, so the engine must never be
# asked about them — otherwise every page describing the template fails.
DOC='Add `NEXT/YYYY-MM-DD-issue-<identity>-<slug>.md`, e.g.
`NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md`.'
template="$(fixture template)"
DOC_FRAGMENT_NAMES_ROOT="$template" bash "$script" >"$tmp/template.out" 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^doc-fragment-names: 1 ' "$tmp/template.out"; } \
  && pass "a placeholder template is not counted as an example" \
  || { fail "placeholder form was checked as a name (rc=$rc)"; sed 's/^/diag - /' "$tmp/template.out"; }

# Test fixtures outside documentation legitimately carry non-canonical names
# (scripts/ci-gate/*.test.sh uses `NEXT/2026-07-20-foo.md`), so the scan is Markdown.
DOC='See `NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md` for the shape.'
scoped="$(fixture scoped)"
printf 'fixture NEXT/2026-07-20-foo.md\n' >"$scoped/scripts/other.test.sh"
git -C "$scoped" add scripts/other.test.sh
git -C "$scoped" commit -qm fixtures
DOC_FRAGMENT_NAMES_ROOT="$scoped" bash "$script" >"$tmp/scoped.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a non-canonical name in a test fixture outside documentation is not a finding" \
  || { fail "the scan reached beyond documentation (rc=$rc)"; sed 's/^/diag - /' "$tmp/scoped.out"; }

# A root that cannot be enumerated must not read as "no examples, all good".
notrepo="$tmp/not-a-repo"
mkdir -p "$notrepo"
printf '%s\n' "$DOC" >"$notrepo/guide.md"
DOC_FRAGMENT_NAMES_ROOT="$notrepo" bash "$script" >"$tmp/notrepo.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an unreadable checkout fails closed instead of finding no examples" \
  || { fail "non-repository root passed (rc=$rc)"; sed 's/^/diag - /' "$tmp/notrepo.out"; }

# The contract itself: this repository's own examples must be names the engine takes.
bash "$script" >"$tmp/self.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "every fragment filename documented in this repository is accepted (#305)" \
  || { fail "this repository documents a fragment name the engine rejects (rc=$rc)"; sed 's/^/diag - /' "$tmp/self.out"; }

# #305 itself: a page that shows only the issue-backed filename lets a reader infer
# that the `-issue-` segment tracks the metadata key. Every page that teaches the
# filename must show the issue-less one beside it.
for page in docs/changelog/README.md docs/changelog/migration.md NEXT/README.md; do
  { grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}-issue-[0-9]+-' "$repo_root/$page" \
    && grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}-issue-[0-9]{8}T[0-9]{6}Z-' "$repo_root/$page"; } \
    && pass "$page shows both the issue-backed and issue-less filename (#305)" \
    || fail "$page does not show both filename forms, so the -issue- segment reads as variable"
done

# A test that actions-ci does not call never runs — the gap that once left
# hold.test.sh dormant here.
grep -q 'bash scripts/doc-fragment-names.test.sh' \
  "$repo_root/.github/workflows/actions-ci.yml" \
  && pass "actions-ci runs this test" \
  || fail "actions-ci does not run scripts/doc-fragment-names.test.sh, so it is dormant"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
