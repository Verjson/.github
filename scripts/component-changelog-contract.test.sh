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
git clone -q --no-checkout "$root" "$contract"
git -C "$contract" checkout -q --detach "$pin"
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
  local file="$1" issue="$2" title="$3" component="${4:-}"
  {
    echo "---"
    echo "date: 2026-08-07"
    echo "issue: $issue"
    [ -z "$component" ] || echo "component: $component"
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
(cd "$consumer" && scripts/changelog-contract.test.sh) >/dev/null

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
(cd "$consumer" && scripts/changelog-contract.test.sh) >/dev/null

release_stream python-v1.0.0 "Python stream" python
[ -f "$consumer/NEXT/2026-08-07-issue-392-node.md" ] \
  || { echo "FAIL - Python release consumed the Node stream"; exit 1; }
(cd "$consumer" && scripts/changelog-contract.test.sh) >/dev/null

release_stream node-v1.0.0 "Node stream" node
[ -z "$(find "$consumer/NEXT" -maxdepth 1 -type f -name '*.md' -print -quit)" ] \
  || { echo "FAIL - exact releases left a selected fragment behind"; exit 1; }
(cd "$consumer" && scripts/changelog-contract.test.sh) >/dev/null

echo "ok - generated artifacts isolate three disposable release streams at $pin"
