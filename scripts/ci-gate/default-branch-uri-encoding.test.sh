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
# Python callers build the same two URLs, so the same two encodings apply by position.
# `urllib.parse.quote` defaults to `safe="/"`, which is the QUERY form: `quote(v)` and
# `quote(v, safe="/")` keep "/" literal, and only `quote(v, safe="")` encodes it as %2F for
# a path segment. Those names orient a reader only — the check below evaluates each encoder
# call against the same fixtures the jq programs face, so a mis-stated mapping cannot make a
# wrong call pass.
#
# This test asserts three independent things:
#   1. behavior  — the two extractable gate-rearm blocks really encode what they read;
#   2. semantics — every encoder expression in the repository maps the fixtures correctly;
#   3. coverage  — an allowlist over the ref interpolations it can RECOGNIZE in workflows
#      and non-test shell and Python scripts, so a new unencoded site fails here instead of
#      merely being spelled differently from a denylist pattern.
#
# Read that third one narrowly. The scan is anchored on syntax: f-string and `str.format`
# brace interpolation in Python, `$VAR` interpolation in shell. The same URL built by
# concatenation (`"...?ref=" + branch`), by `%`-formatting, or across two statements is
# invisible to it, and so is a ref-bearing URL shape the anchor list does not name. Those
# are limits of the recognizer, not sites judged safe. Widening both is tracked in #1464,
# which carries a measured example: flipping a real path-segment encoder to the query form
# leaves this check green today. Do not read a green run here as "every ref interpolation
# in this repository is encoded correctly".
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
# Shared scan: every ref interpolation in workflows and non-test shell and Python scripts.
#   query value  -> `?ref=$VAR`     (shell) or `?ref={EXPR}`     (Python)
#   path segment -> `git/ref[s]/heads/$VAR` or `git/ref[s]/heads/{EXPR}`
# A `.py` file is scanned for both syntaxes: it may build a URL itself, and it may also emit
# shell that does (the generated node required-workflow admission step is one).
# `*.test.sh`, `*.test.py` and `*_test.py` are excluded deliberately: their `?ref=` strings
# are stub matchers and expected-URL assertions, not privileged reads.
# --------------------------------------------------------------------------------------
mapfile -t scanned < <(
  git -C "$root" ls-files -- '.github/workflows/*.yml' 'scripts/*.sh' 'scripts/*.py' \
    | grep -vE '(\.test\.(sh|py)|_test\.py)$'
)
[ "${#scanned[@]}" -gt 0 ] || fail "the ref-interpolation scan matched no files"

FUNC_HEADER='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[(][)][[:space:]]*[({]'
PY_FUNC_HEADER='^[[:space:]]*def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[(]'

# Emits "file<TAB>line<TAB>kind<TAB>subject<TAB>syntax" for every ref interpolation in the
# repository. `syntax` is shvar for a `$name` interpolation and pyexpr for a `{expression}`
# one, because the two prove themselves differently.
ref_sites() {
  local file line text var expr
  for file in "${scanned[@]}"; do
    # Whole-line comments describe these URLs; they do not build one.
    while IFS=$'\t' read -r line text; do
      while read -r var; do
        printf '%s\t%s\tquery\t%s\tshvar\n' "$file" "$line" "${var#?ref=$}"
      done < <(grep -oE '\?ref=\$[A-Za-z_][A-Za-z0-9_]*' <<<"$text" || true)
      while read -r var; do
        var="${var##*/\$}"
        printf '%s\t%s\tpath\t%s\tshvar\n' "$file" "$line" "$var"
      done < <(grep -oE 'git/refs?/heads/\$[A-Za-z_][A-Za-z0-9_]*' <<<"$text" || true)
      [ "${file##*.}" = py ] || continue
      while IFS= read -r expr; do
        expr="${expr#\?ref=\{}"
        printf '%s\t%s\tquery\t%s\tpyexpr\n' "$file" "$line" "${expr%\}}"
      done < <(grep -oE '\?ref=\{[^}]+\}' <<<"$text" || true)
      while IFS= read -r expr; do
        expr="${expr#*heads/\{}"
        printf '%s\t%s\tpath\t%s\tpyexpr\n' "$file" "$line" "${expr%\}}"
      done < <(grep -oE 'git/refs?/heads/\{[^}]+\}' <<<"$text" || true)
    done < <(grep -nE '\?ref=[$\{]|git/refs?/heads/[$\{]' "$root/$file" \
      | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/:/\t/' || true)
  done
}

# The proof for a value must sit between the top of its enclosing function (or the top of
# the file) and its use, so a guard in a sibling block cannot vouch for it. A `.py` file
# that emits shell doubles its braces to survive `str.format`, so the slice is normalized
# back before any shell-shaped proof is matched against it.
block_slice() {
  local file="$1" line="$2" start re="$FUNC_HEADER"
  [ "${file##*.}" != py ] || re="$PY_FUNC_HEADER"
  start="$(awk -v end="$line" -v re="$re" \
    'NR <= end && $0 ~ re { s = NR } END { print (s ? s : 1) }' "$root/$file")"
  if [ "${file##*.}" = py ]; then
    sed -n "${start},${line}p" "$root/$file" | sed 's/{{/{/g; s/}}/}/g'
  else
    sed -n "${start},${line}p" "$root/$file"
  fi
}

# --------------------------------------------------------------------------------------
# 2. Semantics: evaluate every encoder expression this repository actually ships.
# --------------------------------------------------------------------------------------
encoder_program() { # $1 = block slice, $2 = variable -> the jq program of its @uri assignment
  sed -nE "s/^[[:space:]]*$2=\"\\\$\(jq -rn --arg branch \"[^\"]*\" '(.*)'\)\"\$/\1/p" <<<"$1" \
    | grep '@uri' || true
}

# A Python encoder proves itself the same way a jq program does: the call this repository
# actually ships is evaluated, with only its first argument replaced by the fixture. Nothing
# here pattern-matches `safe=`, so a novel spelling is judged by what it produces.
cat >"$tmp/py-encoder.py" <<'PYSRC'
import ast
import sys
import urllib.parse

expression, value = sys.argv[1], sys.argv[2]
call = ast.parse(expression, mode="eval").body
if not isinstance(call, ast.Call) or not call.args:
    raise SystemExit(f"not a percent-encoding call: {expression}")
name = call.func.attr if isinstance(call.func, ast.Attribute) else getattr(call.func, "id", "")
if name != "quote":
    raise SystemExit(f"not a percent-encoding call: {expression}")
call.args[0] = ast.Constant(value)
namespace = {"urllib": urllib, "quote": urllib.parse.quote}
print(eval(compile(ast.fix_missing_locations(ast.Expression(call)), "<encoder>", "eval"), namespace))
PYSRC

py_encoder_expression() { # $1 = block slice, $2 = interpolated expression -> its quote(…) call
  local slice="$1" subject="$2"
  if [[ "$subject" == *quote\(* ]]; then printf '%s\n' "$subject"; return 0; fi
  [[ "$subject" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  sed -nE "s/^[[:space:]]*$subject[[:space:]]*=[[:space:]]*((urllib\.parse\.)?quote\(.*\))[[:space:]]*\$/\1/p" \
    <<<"$slice" | tail -1
}

assert_py_encoder() { # $1 = label, $2 = python expression, $3 = query|path
  local label="$1" expression="$2" mode="$3" got
  got="$(python3 "$tmp/py-encoder.py" "$expression" "$HOSTILE_BRANCH")" \
    || fail "$label does not evaluate as a percent-encoding call: $expression"
  [ "$got" = "$HOSTILE_ENCODED" ] \
    || fail "$label encodes '$HOSTILE_BRANCH' as '$got', expected '$HOSTILE_ENCODED'"
  got="$(python3 "$tmp/py-encoder.py" "$expression" "$NESTED_BRANCH")" \
    || fail "$label does not evaluate as a percent-encoding call: $expression"
  case "$mode" in
    query)
      [ "$got" = "$NESTED_BRANCH" ] \
        || fail "$label builds a query value and must keep '/' literal, got '$got'" ;;
    path)
      [ "$got" = "$NESTED_PATH_ENCODED" ] \
        || fail "$label builds a path segment and must encode '/' as %2F, got '$got'" ;;
  esac
}

# The Python counterpart of the shell `=~ ^[0-9a-f]{40}$` guard, in the two spellings this
# repository uses. A module-level SHA_PATTERN must itself be the 40-hex pattern.
py_hex_constrained() { # $1 = file, $2 = block slice, $3 = identifier
  local file="$1" slice="$2" var="$3" hex='\[0-9a-f\]\{40\}'
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  grep -qE "re\.fullmatch\(r?['\"][^,]*$hex[^,]*['\"],[[:space:]]*$var([^A-Za-z0-9_]|$)" \
    <<<"$slice" && return 0
  grep -qE "SHA_PATTERN\.fullmatch\($var([^A-Za-z0-9_]|$)" <<<"$slice" || return 1
  grep -qE "^SHA_PATTERN = re\.compile\(r['\"]$hex['\"]\)$" "$root/$file"
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
py_sites=0
py_encoders=0
while IFS=$'\t' read -r file line kind var syntax; do
  sites=$((sites + 1))
  slice="$(block_slice "$file" "$line")"
  if [ "$syntax" = pyexpr ]; then
    py_sites=$((py_sites + 1))
    label="$file:$line {$var}"
    expression="$(py_encoder_expression "$slice" "$var")"
    if [ -n "$expression" ]; then
      py_encoders=$((py_encoders + 1))
      assert_py_encoder "$label" "$expression" "$kind"
      continue
    fi
    py_hex_constrained "$file" "$slice" "$var" && continue
    fail "$label reaches a gh api $kind position without a percent-encoding or a 40-hex constraint in its block"
  fi
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
[ "$py_sites" -ge 8 ] || fail "the ref-interpolation scan found only $py_sites Python sites; it is not reaching the Python callers"
[ "$py_encoders" -ge 4 ] || fail "only $py_encoders Python encoder calls were exercised; the semantics check is not reaching them"

echo "PASS: $sites ref interpolations ($py_sites of them Python) across ${#scanned[@]} workflows"
echo "      and non-test scripts are percent-encoded or 40-hex-constrained, and all $encoders jq"
echo "      and $py_encoders Python encoder expressions keep '/' literal in a query value and"
echo "      encode it as %2F in a path segment"
