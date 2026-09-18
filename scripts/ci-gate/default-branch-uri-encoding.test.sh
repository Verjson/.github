#!/usr/bin/env bash
# The adopter's default branch name is adopter-controlled text. Every gate-rearm read that
# puts it in a `gh api` query string must percent-encode it first, so that relaxing the
# `^[A-Za-z0-9._/-]+$` guard cannot silently re-arm a query-injection path.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
fixture="$root/scripts/ci-gate/fixtures/ai-review-caller-a6b3ccc.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

awk '
  /          select_compatible_review_policy\(\) \{/ { found=1 }
  found && /^          }$/ { sub(/^          /, ""); print; exit }
  found { sub(/^          /, ""); print }
' "$workflow" >"$tmp/selector.sh"
[ -s "$tmp/selector.sh" ] || { echo "FAIL: compatibility selector is missing"; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
cat "$CALLER_FILE"
SH
chmod +x "$tmp/bin/gh"

export PATH="$tmp/bin:$PATH" ACTIONS_TOKEN=actions-token TARGET_REPO=Verjson/example
export CALLER_FILE="$fixture" GH_CALLS="$tmp/gh-calls"
# shellcheck source=/dev/null
source "$tmp/selector.sh"
policy='{"actor":"trusted-arm","actor_permission":"automation","authority":"human","budget_usd":"auto","explicit_rereview":false,"fallback_budget_usd":"","fallback_model":"","model":"auto","pricing_version":"anthropic-native-v1","provider":"anthropic"}'

: >"$GH_CALLS"
DEFAULT_BRANCH='release#1&2' select_compatible_review_policy "$policy" >/dev/null
if ! grep -qF 'ai-review-merge.yml?ref=release%231%262' "$GH_CALLS"; then
  echo "FAIL: default branch reached the caller-read query string unencoded: $(cat "$GH_CALLS")"; exit 1
fi
if grep -qF 'ref=release#1&2' "$GH_CALLS"; then
  echo "FAIL: raw default branch survived in the caller-read query string"; exit 1
fi

: >"$GH_CALLS"
DEFAULT_BRANCH='release/2026.09' select_compatible_review_policy "$policy" >/dev/null
if ! grep -qF 'ai-review-merge.yml?ref=release/2026.09' "$GH_CALLS"; then
  echo "FAIL: a path-shaped default branch must keep its separators literal: $(cat "$GH_CALLS")"; exit 1
fi

if grep -n 'ref=\$DEFAULT_BRANCH' "$workflow"; then
  echo "FAIL: the lines above interpolate the default branch into a query string unencoded"; exit 1
fi

echo "PASS: every default-branch query-string read is percent-encoded and slash-preserving"
