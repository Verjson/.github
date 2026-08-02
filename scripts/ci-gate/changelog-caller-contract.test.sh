#!/usr/bin/env bash
# Contract tests for scripts/gen-changelog-caller.sh (#286).
#
# The generated pair fails silently when wrong — a renderer and a workflow
# pinned to different commits both keep working while local output stops
# predicting CI — so the agreement between them is asserted here rather than
# left to reviewers.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
gen="$repo_root/scripts/gen-changelog-caller.sh"
sha="0123456789abcdef0123456789abcdef01234567"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -x "$gen" ] || { echo "FAIL - $gen is not executable"; exit 1; }

workflow="$(bash "$gen" workflow "$sha")"
renderer="$(bash "$gen" renderer "$sha")"

# 1. The workflow pins its `uses:` and its contract_ref to the same commit.
uses_ref="$(printf '%s\n' "$workflow" | sed -n 's#.*changelog-validate\.yml@\([0-9a-f]\{40\}\).*#\1#p')"
input_ref="$(printf '%s\n' "$workflow" | sed -n 's/^ *contract_ref: \([0-9a-f]\{40\}\) *$/\1/p')"
[ "$uses_ref" = "$sha" ] && pass "workflow pins uses: to the requested commit" \
  || fail "workflow uses: is '$uses_ref', expected $sha"
[ "$input_ref" = "$sha" ] && pass "workflow passes contract_ref as the same commit" \
  || fail "workflow contract_ref is '$input_ref', expected $sha"

# 2. The renderer pins the same commit the workflow validates with.
script_ref="$(printf '%s\n' "$renderer" | sed -n 's/^CONTRACT_REF="\([0-9a-f]\{40\}\)"$/\1/p')"
[ "$script_ref" = "$uses_ref" ] \
  && pass "renderer and workflow share one contract commit" \
  || fail "renderer pins '$script_ref' but workflow pins '$uses_ref'"

# 3. The renderer is valid bash and renders nothing on its own.
printf '%s\n' "$renderer" | bash -n \
  && pass "generated renderer parses as bash" || fail "generated renderer is not valid bash"

# 4. Least privilege: the workflow requests no write scope.
printf '%s\n' "$workflow" | grep -q 'contents: read' \
  && pass "workflow declares contents: read" || fail "workflow does not declare contents: read"
printf '%s\n' "$workflow" | grep -qE '\bwrite\b' \
  && fail "workflow requests a write permission" || pass "workflow requests no write permission"

# 5. A ref that is not a bare commit is rejected, not quoted and passed through.
# An earlier sibling generator accepted a ref and let YAML be injected through
# it; the guard is asserted, not assumed.
for bad in 'main' "$(printf 'main\n    if: false')" '../../evil' "${sha^^}" "${sha}0" ''; do
  if bash "$gen" workflow "$bad" >/dev/null 2>&1; then
    fail "generator accepted a non-commit ref: '$bad'"
  else
    pass "generator rejects non-commit ref: '${bad//$'\n'/\\n}'"
  fi
done

# 6. An unknown mode fails rather than emitting an empty file.
bash "$gen" bogus "$sha" >/dev/null 2>&1 \
  && fail "generator accepted an unknown mode" || pass "generator rejects an unknown mode"

# 7. The emitted renderer fails closed when the contract cannot be fetched, and
# leaves no partial file behind for the next run to exec as if it were the
# contract. Exercised with a stubbed curl so no network is required.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT
mkdir -p "$tmproot/repo/scripts" "$tmproot/repo/NEXT" "$tmproot/bin" "$tmproot/cache"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$tmproot/bin/curl"
chmod +x "$tmproot/bin/curl"
printf '%s\n' "$renderer" > "$tmproot/repo/scripts/render-next.sh"

set +e
PATH="$tmproot/bin:$PATH" XDG_CACHE_HOME="$tmproot/cache" \
  bash "$tmproot/repo/scripts/render-next.sh" >/dev/null 2>"$tmproot/err"
rc=$?
set -e

[ "$rc" -ne 0 ] \
  && pass "generated renderer exits non-zero when the contract cannot be fetched" \
  || fail "generated renderer exited 0 despite a failed fetch"
grep -q 'cannot fetch the changelog contract' "$tmproot/err" \
  && pass "generated renderer reports why the fetch failed" \
  || fail "generated renderer gave no fetch-failure diagnostic"
[ -z "$(find "$tmproot/cache" -name '.changelog.*' 2>/dev/null)" ] \
  && pass "generated renderer leaves no partial download behind" \
  || fail "generated renderer left a partial download in the cache"
[ ! -f "$tmproot/cache/verjson-changelog/$sha/changelog.py" ] \
  && pass "generated renderer does not create the contract on failure" \
  || fail "generated renderer created a contract file from a failed fetch"

[ "$fails" -eq 0 ] || exit 1
echo "All tests passed."
