#!/usr/bin/env bash
# Execute generated component-scoped artifacts through three exact releases (#390).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(sed -nE 's/^<!-- recommended-contract-pin: ([0-9a-f]{40}) -->$/\1/p' \
  "$root/docs/changelog/README.md")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
contract="$tmp/contract"
consumer="$tmp/consumer"

[ -n "$pin" ] || { echo "FAIL - no recommended contract pin"; exit 1; }
git init -q "$contract"
if git -C "$root" cat-file -e "$pin^{commit}" 2>/dev/null; then
  contract_source="$root"
else
  contract_source="$(git -C "$root" remote get-url origin)" \
    || { echo "FAIL - documented pin $pin is absent and origin is unavailable"; exit 1; }
fi
git -C "$contract" fetch -q --no-tags --depth=1 "$contract_source" "$pin" \
  || { echo "FAIL - cannot fetch documented contract pin $pin"; exit 1; }
git -C "$contract" checkout -q --detach FETCH_HEAD
[ "$(git -C "$contract" rev-parse HEAD)" = "$pin" ] \
  || { echo "FAIL - canonical checkout does not equal $pin"; exit 1; }

mkdir -p "$consumer/.github/workflows" "$consumer/scripts" "$consumer/NEXT"
"$contract/scripts/gen-changelog-caller.sh" workflow "$pin" \
  >"$consumer/.github/workflows/changelog.yml"
"$contract/scripts/gen-changelog-caller.sh" renderer "$pin" \
  >"$consumer/scripts/render-next.sh"
"$contract/scripts/gen-changelog-caller.sh" contract-test "$pin" \
  >"$consumer/scripts/changelog-contract.test.sh"
"$contract/scripts/gen-changelog-caller.sh" release-node "$pin" \
  >"$consumer/.github/workflows/release.yml"
chmod +x "$consumer/scripts/render-next.sh" "$consumer/scripts/changelog-contract.test.sh"

grep -qE '^ +component: .*\$\{\{ inputs\.component \}\}' \
  "$consumer/.github/workflows/release.yml" \
  || { echo "FAIL - generated release caller drops component selection"; exit 1; }

write_fragment() {
  local file="$1" issue="$2" title="$3" component="${4:-}" impact="${5:-}"
  {
    echo "---"
    echo "date: 2026-08-07"
    echo "issue: $issue"
    [ -z "$component" ] || echo "component: $component"
    [ -z "$impact" ] || echo "impact: $impact"
    echo "title: $title"
    echo "---"
    echo
    echo "$title release note."
  } >"$consumer/NEXT/$file"
}

write_fragment 2026-08-07-issue-390-default.md 390 "Default stream"
write_fragment 2026-08-07-issue-391-python.md 391 "Python stream" python
write_fragment 2026-08-07-issue-392-node.md 392 "Node stream" node

git -C "$consumer" init -q
git -C "$consumer" config user.name test
git -C "$consumer" config user.email test@example.com
git -C "$consumer" add -A
git -C "$consumer" commit -qm fixture

export CHANGELOG_CONTRACT_PATH="$contract/scripts/changelog.py"
(cd "$consumer" && scripts/changelog-contract.test.sh)

default_render="$(cd "$consumer" && scripts/render-next.sh)"
python_render="$(cd "$consumer" && scripts/render-next.sh --component python)"
[[ "$default_render" == *"## Default stream"* && "$default_render" != *"Python stream"* ]] \
  || { echo "FAIL - default renderer leaked a scoped stream"; exit 1; }
[[ "$python_render" == *"## Python stream"* && "$python_render" != *"Default stream"* ]] \
  || { echo "FAIL - component renderer mixed streams"; exit 1; }

release_stream() {
  local version="$1" expected="$2" component="${3:-}"
  local -a args=()
  [ -z "$component" ] || args=(--component "$component")
  python3 "$contract/scripts/changelog.py" release \
    --repo-root "$consumer" --version "$version" "${args[@]}"
  grep -q "^## $expected$" "$consumer/CHANGELOG/$version.md" \
    || { echo "FAIL - $version omitted $expected"; exit 1; }
}

release_stream v1.0.0 "Default stream"
[ -f "$consumer/NEXT/2026-08-07-issue-391-python.md" ] \
  && [ -f "$consumer/NEXT/2026-08-07-issue-392-node.md" ] \
  || { echo "FAIL - default release consumed a scoped stream"; exit 1; }
(cd "$consumer" && scripts/changelog-contract.test.sh)

release_stream python-v1.0.0 "Python stream" python
[ -f "$consumer/NEXT/2026-08-07-issue-392-node.md" ] \
  || { echo "FAIL - Python release consumed the Node stream"; exit 1; }
(cd "$consumer" && scripts/changelog-contract.test.sh)

release_stream node-v1.0.0 "Node stream" node

write_fragment 2026-08-07-issue-393-default-patch.md \
  393 "Default patch" "" patch
write_fragment 2026-08-07-issue-394-python-major.md \
  394 "Python major" python major
write_fragment 2026-08-07-issue-395-node-minor.md \
  395 "Node minor" node minor
git -C "$consumer" add -A
git -C "$consumer" commit -qm "mixed stream impacts"

release_stream v1.0.1 "Default patch"
release_stream python-v2.0.0 "Python major" python

before="$(git -C "$consumer" status --porcelain)"
if python3 "$contract/scripts/changelog.py" release \
  --repo-root "$consumer" --version node-v1.0.1 --component node \
  2>"$tmp/impact-error"; then
  echo "FAIL - Node release ignored its selected minor impact"
  exit 1
fi
grep -q 'require a minor bump' "$tmp/impact-error" \
  || { echo "FAIL - Node impact rejection gave no actionable error"; exit 1; }
[ "$(git -C "$consumer" status --porcelain)" = "$before" ] \
  || { echo "FAIL - rejected Node impact mutated consumer"; exit 1; }
release_stream node-v1.1.0 "Node minor" node

[ -z "$(find "$consumer/NEXT" -maxdepth 1 -type f -name '*.md' -print -quit)" ] \
  || { echo "FAIL - exact releases left a selected fragment behind"; exit 1; }
(cd "$consumer" && scripts/changelog-contract.test.sh)

echo "ok - generated artifacts isolate three disposable release streams at $pin"
