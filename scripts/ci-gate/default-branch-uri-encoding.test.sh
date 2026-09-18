#!/usr/bin/env bash
# Adopter ref names (the default branch, a PR head branch) are adopter-controlled text.
# Every `gh api` URL that interpolates one must percent-encode it first, so that relaxing
# the `^[A-Za-z0-9._/-]+$` guards cannot silently re-arm an injection path.
#
# Two encodings exist, and they are not interchangeable:
#   query value  `…?ref=$branch_ref`   — `@uri` with `gsub("%2F"; "/")`: "/" is an ordinary
#                                        character in a query value and the API wants it
#                                        literal.
#   path segment `…/git/ref/heads/$…`  — `@uri` WITHOUT the gsub: a literal "/" there
#                                        re-addresses the resource, so a branch named
#                                        `../../x` would escape the endpoint entirely.
#
# This test asserts three independent things:
#   1. behavior  — the two extractable gate-rearm blocks really encode what they read;
#   2. semantics — every encoder expression in the repository maps the fixtures correctly;
#   3. coverage  — an allowlist over EVERY ref interpolation in workflows and non-test
#      scripts, so a new unencoded site fails here instead of merely being spelled
#      differently from a denylist pattern.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/gate-rearm.yml"
fixture="$root/scripts/ci-gate/fixtures/ai-review-caller-a6b3ccc.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

HOSTILE_BRANCH='release#1&2'
HOSTILE_ENCODED='release%231%262'
NESTED_BRANCH='release/2026.09'
NESTED_PATH_ENCODED='release%2F2026.09'
BLOB_SHA=1111111111111111111111111111111111111111
WORKFLOW_SHA=2222222222222222222222222222222222222222

fail() { echo "FAIL: $*"; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_STUB_STDOUT:-}" ]; then printf '%s\n' "$GH_STUB_STDOUT"; else cat "$CALLER_FILE"; fi
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" ACTIONS_TOKEN=actions-token TARGET_REPO=Verjson/example
export CALLER_FILE="$fixture" GH_CALLS="$tmp/gh-calls"

# --------------------------------------------------------------------------------------
# 1a. Behavior: the compatibility selector's protected caller read.
# --------------------------------------------------------------------------------------
awk '
  /          select_compatible_review_policy\(\) \{/ { found=1 }
  found && /^          }$/ { sub(/^          /, ""); print; exit }
  found { sub(/^          /, ""); print }
' "$workflow" >"$tmp/selector.sh"
[ -s "$tmp/selector.sh" ] || fail "compatibility selector is missing"
# shellcheck source=/dev/null
source "$tmp/selector.sh"
policy='{"actor":"trusted-arm","actor_permission":"automation","authority":"human","budget_usd":"auto","explicit_rereview":false,"fallback_budget_usd":"","fallback_model":"","model":"auto","pricing_version":"anthropic-native-v1","provider":"anthropic"}'

: >"$GH_CALLS"
DEFAULT_BRANCH="$HOSTILE_BRANCH" select_compatible_review_policy "$policy" >/dev/null
grep -qF "ai-review-merge.yml?ref=$HOSTILE_ENCODED" "$GH_CALLS" \
  || fail "default branch reached the caller-read query string unencoded: $(cat "$GH_CALLS")"
! grep -qF "ref=$HOSTILE_BRANCH" "$GH_CALLS" \
  || fail "raw default branch survived in the caller-read query string"

: >"$GH_CALLS"
DEFAULT_BRANCH="$NESTED_BRANCH" select_compatible_review_policy "$policy" >/dev/null
grep -qF "ai-review-merge.yml?ref=$NESTED_BRANCH" "$GH_CALLS" \
  || fail "a path-shaped default branch must keep its separators literal in a query value: $(cat "$GH_CALLS")"

# --------------------------------------------------------------------------------------
# 1b. Behavior: the cross-run orphan-recovery receipt block. Extracted the same way as the
#     selector, so its encoding is covered by execution rather than by a spelling match.
# --------------------------------------------------------------------------------------
awk '
  !found && $0 == "              if [ \"$(jq -r .path <<<\"$source_run\")\" = .github/workflows/ai-review-label-rearm.yml ]; then" { found=1 }
  found {
    line = $0
    sub(/^              /, "", line)
    print line
    if ($0 == "              fi") exit
  }
' "$workflow" >"$tmp/recovery-body.sh"
[ -s "$tmp/recovery-body.sh" ] || fail "cross-run orphan-recovery receipt block is missing"
{ printf 'verify_recovery_receipt() {\n'; cat "$tmp/recovery-body.sh"; printf '  return 0\n}\n'; } \
  >"$tmp/recovery.sh"
# shellcheck source=/dev/null
source "$tmp/recovery.sh"

drive_recovery() {
  local branch="$1" receipt_dir="$tmp/receipt" source_run
  source_run='{"path":".github/workflows/ai-review-label-rearm.yml","actor":{"login":"trusted-arm"}}'
  rm -rf "$receipt_dir"; mkdir -p "$receipt_dir"
  cat >"$receipt_dir/receipt.json" <<JSON
{"schema":2,"workflow_sha":"$WORKFLOW_SHA","delivery_event":"pull_request_target",
 "delivery_actor":"trusted-arm",
 "workflow_ref":"$TARGET_REPO/.github/workflows/ai-review-label-rearm.yml@refs/heads/$branch"}
JSON
  : >"$GH_CALLS"
  DEFAULT_BRANCH="$branch" GH_STUB_STDOUT="$BLOB_SHA" verify_recovery_receipt \
    || fail "the recovery receipt block rejected its own fixture for branch '$branch'"
}

drive_recovery "$HOSTILE_BRANCH"
grep -qF "ai-review-label-rearm.yml?ref=$HOSTILE_ENCODED" "$GH_CALLS" \
  || fail "default branch reached the recovery-block query string unencoded: $(cat "$GH_CALLS")"
! grep -qF "ref=$HOSTILE_BRANCH" "$GH_CALLS" \
  || fail "raw default branch survived in the recovery-block query string"

drive_recovery "$NESTED_BRANCH"
grep -qF "ai-review-label-rearm.yml?ref=$NESTED_BRANCH" "$GH_CALLS" \
  || fail "a path-shaped default branch must keep its separators literal in the recovery block: $(cat "$GH_CALLS")"

# --------------------------------------------------------------------------------------
# Shared scan: every ref interpolation in workflows and non-test scripts.
#   query value  -> `?ref=$VAR`
#   path segment -> `git/ref/heads/$VAR` or `git/refs/heads/$VAR`
# `*.test.sh` files are excluded deliberately: their `?ref=` strings are stub matchers and
# expected-URL assertions, not privileged reads.
# --------------------------------------------------------------------------------------
mapfile -t scanned < <(
  git -C "$root" ls-files -- '.github/workflows/*.yml' 'scripts/*.sh' | grep -v '\.test\.sh$'
)
[ "${#scanned[@]}" -gt 0 ] || fail "the ref-interpolation scan matched no files"

FUNC_HEADER='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[(][)][[:space:]]*[({]'

# Emits "file<TAB>line<TAB>kind<TAB>variable" for every ref interpolation in the repository.
ref_sites() {
  local file line text var
  for file in "${scanned[@]}"; do
    # Whole-line comments describe these URLs; they do not build one.
    while IFS=$'\t' read -r line text; do
      while read -r var; do
        printf '%s\t%s\tquery\t%s\n' "$file" "$line" "${var#?ref=$}"
      done < <(grep -oE '\?ref=\$[A-Za-z_][A-Za-z0-9_]*' <<<"$text" || true)
      while read -r var; do
        var="${var##*/\$}"
        printf '%s\t%s\tpath\t%s\n' "$file" "$line" "$var"
      done < <(grep -oE 'git/refs?/heads/\$[A-Za-z_][A-Za-z0-9_]*' <<<"$text" || true)
    done < <(grep -nE '\?ref=\$|git/refs?/heads/\$' "$root/$file" \
      | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/:/\t/' || true)
  done
}

# The proof for a value must sit between the top of its enclosing function (or the top of
# the file) and its use, so a guard in a sibling block cannot vouch for it.
block_slice() {
  local file="$1" line="$2" start
  start="$(awk -v end="$line" -v re="$FUNC_HEADER" \
    'NR <= end && $0 ~ re { s = NR } END { print (s ? s : 1) }' "$root/$file")"
  sed -n "${start},${line}p" "$root/$file"
}

# --------------------------------------------------------------------------------------
# 2. Semantics: evaluate every encoder expression this repository actually ships.
# --------------------------------------------------------------------------------------
encoder_program() { # $1 = block slice, $2 = variable -> the jq program of its @uri assignment
  sed -nE "s/^[[:space:]]*$2=\"\\\$\(jq -rn --arg branch \"[^\"]*\" '(.*)'\)\"\$/\1/p" <<<"$1" \
    | grep '@uri' || true
}

assert_encoder() { # $1 = label, $2 = jq program, $3 = query|path
  local label="$1" program="$2" mode="$3" got
  got="$(jq -rn --arg branch "$HOSTILE_BRANCH" "$program")"
  [ "$got" = "$HOSTILE_ENCODED" ] \
    || fail "$label encodes '$HOSTILE_BRANCH' as '$got', expected '$HOSTILE_ENCODED'"
  got="$(jq -rn --arg branch "$NESTED_BRANCH" "$program")"
  case "$mode" in
    query)
      [ "$got" = "$NESTED_BRANCH" ] \
        || fail "$label builds a query value and must keep '/' literal, got '$got'" ;;
    path)
      [ "$got" = "$NESTED_PATH_ENCODED" ] \
        || fail "$label builds a path segment and must encode '/' as %2F, got '$got'" ;;
  esac
}

# --------------------------------------------------------------------------------------
# 3. Coverage: the allowlist. Each site proves its value safe, or this test fails.
# --------------------------------------------------------------------------------------
sites=0
encoders=0
while IFS=$'\t' read -r file line kind var; do
  sites=$((sites + 1))
  slice="$(block_slice "$file" "$line")"
  label="$file:$line \$$var"
  program="$(encoder_program "$slice" "$var")"
  if [ -n "$program" ]; then
    encoders=$((encoders + 1))
    assert_encoder "$label" "$program" "$kind"
    continue
  fi
  # A 40-hex-constrained value needs no encoding: the constraint already excludes every
  # character that could change the meaning of the URL.
  if grep -qF "[[ \"\$$var\" =~ ^[0-9a-f]{40}\$ ]]" <<<"$slice"; then
    continue
  fi
  if grep -qE "(^|[[:space:]])$var[:=][[:space:]]*[\"']?[0-9a-f]{40}[\"']?[[:space:]]*\$" <<<"$slice"; then
    continue
  fi
  fail "$label reaches a gh api $kind position without a percent-encoding or a 40-hex constraint in its block"
done < <(ref_sites)

[ "$sites" -ge 20 ] || fail "the ref-interpolation scan found only $sites sites; it is not reaching the repository"
[ "$encoders" -ge 10 ] || fail "only $encoders encoder expressions were exercised; the semantics check is not reaching the fixed sites"

echo "PASS: $sites ref interpolations across ${#scanned[@]} workflows and non-test scripts are"
echo "      percent-encoded or 40-hex-constrained, and all $encoders encoder expressions keep"
echo "      '/' literal in a query value and encode it as %2F in a path segment"
