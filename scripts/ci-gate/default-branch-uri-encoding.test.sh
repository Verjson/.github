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
# Read that third one narrowly, and read the ceiling below before trusting a green run.
#
# #1464 widened the anchors from two URL shapes to the ref-bearing path segments listed in
# REF_PATH_SEGMENT (`git/ref[s]/heads/`, `commits/`, `git/commits/`, `git/trees/`,
# `git/tags/`, `branches/` including `rules/branches/`, and BOTH operands of a
# `compare/A...B` range), and taught the shell anchor that `${VAR}` is the same
# interpolation as `$VAR`. That took the scan from 35 recognized sites to 77. Section 0
# measures each of those shapes against synthetic files, so a regression reports which
# shape went blind rather than simply finding fewer sites.
#
# THE CEILING — these reach a ref-bearing URL and this scan still does NOT see them:
#   * Non-brace construction in Python. `read("...?ref=" + branch)`, `"...?ref=%s" % branch`,
#     and a two-statement `url = "...?ref="` / `url += branch` build the same URL and come
#     back unseen. This is a DELIBERATE ceiling, not an oversight: every ref URL in this
#     repository is built with an f-string or `str.format`, and recognizing the others needs
#     an AST/dataflow pass rather than a line anchor -- a line anchor for `+` would be
#     evadable in exactly the way the two-shape anchor was. Keep building these URLs with
#     brace interpolation; a site that stops is a site this test stops covering.
#   * Python embedded in workflow YAML. `{EXPR}` interpolation is only extracted from `.py`
#     files, so the inline Python in `container-deployment.yml` (5 ref-bearing lines as of
#     #1464) is outside the scan.
#   * Shell positional parameters. `commits/$1` is skipped because the subject must be a
#     name; the proof for a positional is at the call site, not at the use.
#   * An interpolation split across source lines, and any ref-bearing path segment not in
#     REF_PATH_SEGMENT.
#   * The sites in REF_SITE_ALLOWLIST -- exempted by hand, each with its reason.
# Do not read a green run here as "every ref interpolation in this repository is encoded
# correctly". Read it as "every shape this scan recognizes is".
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
#   query value  -> `?ref=$VAR`          (shell) or `?ref={EXPR}`          (Python)
#   path segment -> `<ref-segment>/$VAR` (shell) or `<ref-segment>/{EXPR}` (Python), where
#                   <ref-segment> is any of the ref-bearing GitHub REST path segments in
#                   REF_PATH_SEGMENT below, plus the second operand of a `compare/A...B`.
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

# The GitHub REST path segments whose next component names a ref (a branch name, a tag, or
# a commit-ish). A literal "/" in any of them re-addresses the resource exactly the way it
# does in `git/refs/heads/`, so they all take the path encoding, never the query one.
# `branches` also covers `rules/branches`; `commits` also covers `git/commits`.
REF_PATH_SEGMENT='(git/refs?/heads|git/commits|git/trees|git/tags|commits|branches|compare)'
# `$name` and `${name}` are the same shell interpolation; the scan must not be evadable by
# adding braces.
SHVAR='\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'

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
        var="${var##*/\$}"; var="${var#\{}"; var="${var%\}}"
        printf '%s\t%s\tpath\t%s\tshvar\n' "$file" "$line" "$var"
      done < <(grep -oE "${REF_PATH_SEGMENT}/${SHVAR}" <<<"$text" || true)
      if [[ "$text" == *compare/* ]]; then
        while read -r var; do
          var="${var##*...\$}"; var="${var#\{}"; var="${var%\}}"
          printf '%s\t%s\tpath\t%s\tshvar\n' "$file" "$line" "$var"
        done < <(grep -oE "\.\.\.${SHVAR}" <<<"$text" || true)
      fi
      [ "${file##*.}" = py ] || continue
      while IFS= read -r expr; do
        expr="${expr#\?ref=\{}"
        printf '%s\t%s\tquery\t%s\tpyexpr\n' "$file" "$line" "${expr%\}}"
      done < <(grep -oE '\?ref=\{[^}]+\}' <<<"$text" || true)
      while IFS= read -r expr; do
        expr="${expr##*/\{}"
        printf '%s\t%s\tpath\t%s\tpyexpr\n' "$file" "$line" "${expr%\}}"
      done < <(grep -oE "${REF_PATH_SEGMENT}/\{[^}]+\}" <<<"$text" || true)
      if [[ "$text" == *compare/* ]]; then
        while IFS= read -r expr; do
          expr="${expr##*...\{}"
          printf '%s\t%s\tpath\t%s\tpyexpr\n' "$file" "$line" "${expr%\}}"
        done < <(grep -oE '\.\.\.\{[^}]+\}' <<<"$text" || true)
      fi
    done < <(grep -nE '\?ref=[$\{]|'"${REF_PATH_SEGMENT}"'/[$\{]|compare/' "$root/$file" \
      | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/:/\t/' || true)
  done
}

# `$tmp/py-encoder.py` evaluates a `quote(…)` call against the stdlib binding it installs.
# A file that re-binds `quote` at module scope would therefore be judged by a function it
# never calls, so such a file is rejected outright instead of evaluated. Importing the
# stdlib function under its own name is the one binding that is not a shadow.
py_quote_unshadowed() { # $1 = file (relative to $root) -> 0 when module scope keeps `quote`
  local file="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ ^from[[:space:]]+urllib\.parse[[:space:]]+import[[:space:]]+[A-Za-z0-9_,\ ]+$ ]] \
      || return 1
  done < <(grep -E '^(def|async def|class)[[:space:]]+quote[[:space:]]*[(:]|^quote[[:space:]]*[:=]|^import[[:space:]].*[[:space:]]as[[:space:]]+quote[[:space:]]*$|^from[[:space:]].*[[:space:]]import[[:space:]].*\bquote\b' \
    "$root/$file" || true)
  return 0
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
# 0. The recognizer's own coverage, measured rather than described. Each case below is a
#    shape that reached a ref-bearing URL position while this scan reported green (#1464).
#    They run against synthetic files, not the repository, so a real site being fixed or
#    moved cannot quietly retire one.
# --------------------------------------------------------------------------------------
mkdir -p "$tmp/fx"
recognizer_sees() { # $1 = label, $2 = filename, $3 = expected "kind<TAB>subject", $4… = lines
  local label="$1" name="$2" expected="$3"; shift 3
  printf '%s\n' "$@" >"$tmp/fx/$name"
  ( root="$tmp/fx"; scanned=("$name"); ref_sites ) | cut -f3,4 | grep -qxF "$expected" \
    || fail "the ref scan is blind to $label"
}

recognizer_sees 'a ref in a commits/ path segment (shell)' anchor-commits.sh \
  $'path\tdefault_branch' 'gh api "repos/$REPO/commits/$default_branch"'
recognizer_sees 'a ref in a commits/ path segment (Python)' anchor-commits.py \
  $'path\tdefault_branch' 'run_gh(f"repos/{repo}/commits/{default_branch}")'
recognizer_sees 'a ref in a git/commits/ path segment' anchor-git-commits.py \
  $'path\thead_sha' 'client.request("GET", f"repos/{repo}/git/commits/{head_sha}")'
recognizer_sees 'a ref in a git/trees/ path segment' anchor-git-trees.py \
  $'path\tref' 'gh("api", f"repos/{HUB}/git/trees/{ref}?recursive=1")'
recognizer_sees 'a ref in a git/tags/ path segment' anchor-git-tags.py \
  $'path\ttag' 'api.call("GET", f"{repo}/git/tags/{tag}", token)'
recognizer_sees 'a ref in a branches/ path segment' anchor-branches.sh \
  $'path\tbranch' 'gh api "repos/$ORG/$repo/branches/$branch"'
recognizer_sees 'a ref in a rules/branches/ path segment' anchor-rules-branches.py \
  $'path\tbase' 'f"repos/{repo}/rules/branches/{base}?per_page=100"'
recognizer_sees 'the LEFT operand of a compare/ range' anchor-compare-left.sh \
  $'path\tbase_ref' 'gh api "repos/$REPO/compare/$base_ref...$head_sha"'
recognizer_sees 'the RIGHT operand of a compare/ range' anchor-compare-right.sh \
  $'path\thead_sha' 'gh api "repos/$REPO/compare/$base_ref...$head_sha"'
recognizer_sees 'the RIGHT operand of a compare/ range (Python)' anchor-compare-right.py \
  $'path\tcurrent' 'gh_json(f"repos/{repo}/compare/{previous}...{current}")'
recognizer_sees 'a ${braced} shell interpolation' anchor-braced.sh \
  $'path\tHEAD_SHA' 'gh api "repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/status"'

# A module-scope `quote` re-binding is rejected outright rather than evaluated: the
# encoder sandbox binds the stdlib `quote`, so a file that ships its own would be judged by
# a function it never calls.
cat >"$tmp/fx/shadowed.py" <<'PYFX'
def quote(value, safe="/"):
    return value


def read(repo, branch):
    return gh(f"repos/{repo}/git/refs/heads/{quote(branch, safe='')}")
PYFX
( root="$tmp/fx"; py_quote_unshadowed shadowed.py ) \
  && fail "a module-scope 'quote' re-binding was accepted as the stdlib encoder"
cat >"$tmp/fx/unshadowed.py" <<'PYFX'
from urllib.parse import quote


def read(repo, branch):
    return gh(f"repos/{repo}/git/refs/heads/{quote(branch, safe='')}")
PYFX
( root="$tmp/fx"; py_quote_unshadowed unshadowed.py ) \
  || fail "the stdlib 'from urllib.parse import quote' was mistaken for a shadow"

# --------------------------------------------------------------------------------------
# 2. Semantics: evaluate every encoder expression this repository actually ships.
# --------------------------------------------------------------------------------------
# $1 = block slice, $2 = variable -> "<jq --arg name><TAB><jq program>" for its @uri
# assignment. The `--arg` name is captured rather than assumed: this repository spells it
# `branch`, `value` and `r`, and a program is only evaluable with the name it actually binds.
encoder_program() {
  sed -nE "s/^[[:space:]]*$2=\"\\\$\(jq -rn --arg ([A-Za-z_][A-Za-z0-9_]*) \"[^\"]*\" '(.*)'\)\"\$/\1\t\2/p" <<<"$1" \
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
  # A dotted attribute path (`args.deployment_commit`) is as matchable as a bare name: the
  # grep below is a literal comparison against the text the file actually ships.
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]] || return 1
  grep -qE "re\.fullmatch\(r?['\"][^,]*$hex[^,]*['\"],[[:space:]]*$var([^A-Za-z0-9_]|$)" \
    <<<"$slice" && return 0
  grep -qE "SHA_PATTERN\.fullmatch\($var([^A-Za-z0-9_]|$)" <<<"$slice" || return 1
  grep -qE "^SHA_PATTERN = re\.compile\(r['\"]$hex['\"]\)$" "$root/$file"
}

assert_encoder() { # $1 = label, $2 = jq program, $3 = query|path, $4 = jq --arg name
  local label="$1" program="$2" mode="$3" arg="$4" got
  got="$(jq -rn --arg "$arg" "$HOSTILE_BRANCH" "$program")"
  [ "$got" = "$HOSTILE_ENCODED" ] \
    || fail "$label encodes '$HOSTILE_BRANCH' as '$got', expected '$HOSTILE_ENCODED'"
  got="$(jq -rn --arg "$arg" "$NESTED_BRANCH" "$program")"
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
#
# A site whose proof this scan cannot see at the point of use is named here, once, with the
# reason it is safe anyway. This is a record, not an escape hatch: an entry is keyed by file
# and interpolated subject, every entry must match at least one live site (a stale one fails
# below), and a NEW site that is not listed still fails. Widening the recognizer so entries
# can be retired is tracked in #1464.
#
# Two reason classes appear here, and nothing else should be added without one:
#   sha  — the value is a 40-hex object name, but its constraint is established in another
#          step, another function, or at the caller, outside this scan's block slice.
#   ref  — the value is a ref name carrying a stated non-encoding guard at its source.
# --------------------------------------------------------------------------------------
REF_SITE_ALLOWLIST=(
  # sha: `.headRefOid` from `gh pr view`; GitHub answers a 40-hex OID or the `// ""`
  # default, and this step is not the one that restates the constraint.
  $'.github/workflows/ai-review-merge.yml\thead_sha'
  # sha: same value; gate-rearm.yml:168 asserts `^[0-9a-f]{40}$` on it in the job that
  # resolves it, which is a different step from the read at :347.
  $'.github/workflows/gate-rearm.yml\thead_sha'
  # sha: `${{ github.event.pull_request.head.sha || github.sha }}` — a GitHub-supplied
  # object name, never adopter text.
  $'.github/workflows/node-ci.yml\tHEAD_SHA'
  # sha: `${{ inputs.head-sha }}`, admitted and re-checked against
  # `ADMITTED_HEAD_SHA` elsewhere in the same protected workflow.
  $'.github/workflows/node-ci-protected.yml\tHEAD_SHA'
  # sha: `git rev-parse HEAD` in the checkout this step just made; git answers a 40-hex
  # object name or fails, and the step runs under `set -euo pipefail`.
  $'.github/workflows/repo-hygiene.yml\tresolved'
  # sha: validated at :89 via `validate_workflow_identity`, whose `re.fullmatch` on the
  # 40-hex pattern lives in that function rather than in `build_receipt`'s own block.
  $'scripts/container_deployment_review_producer.py\targs.producer_commit'
  # sha: `SHA.fullmatch(target['sha'])` on the line above, spelled through `.get()` at the
  # use. Same value, different expression, so the literal match cannot join them up.
  $'scripts/container_deployment_transport.py\ttarget.get('"'"'sha'"'"')'
  # sha: `require(... SHA.fullmatch(probe['workflowCommit']) ...)` in the probe validator,
  # a different function from the transport call.
  $'scripts/container_deployment_transport.py\tprobe['"'"'workflowCommit'"'"']'
  # sha: `hub_tree`'s own parameter. Its two callers pass the literal "main" and a value
  # this module already resolved as an object name; the constraint is at the caller.
  $'scripts/fleet-contract-inventory.py\tref'
  # sha: `head_sha = require_sha(planned["head_sha"], …)` earlier in the same module;
  # `require_sha` is the 40-hex boundary check, but it is a call, not an inline pattern.
  $'scripts/renovate-changelog.py\thead_sha'
  # ref: guarded at verify-arm-receipt.sh:59-60 with `^[A-Za-z0-9._/-]+$` plus explicit
  # rejection of a leading "/", of "..", and of "//" — a traversal guard rather than an
  # encoding, which is the one other shape this test accepts by hand.
  $'scripts/ci-gate/verify-arm-receipt.sh\tarm_base_branch'
  # ref: DELIBERATE and UNRESOLVED. assert-mergeable-head.sh:148 encodes with `@uri` and
  # then gsubs %2F back to "/", i.e. the QUERY form, into a `rules/branches/` PATH segment,
  # because its comment states the literal separator is what addresses the ruleset. Three
  # other sites in this repository (gate_coverage_audit.py:216, required-checks-audit.sh,
  # required-checks-rollout.sh) use the path form for the same endpoint. `branches/` and
  # `commits/` were measured to accept BOTH forms against the live API while widening this
  # scan; `rules/branches/` could not be settled here because no Verjson ruleset targets a
  # slash-bearing ref to compare against. Do not "fix" either side on a guess: settling it
  # is tracked in #1464. `base_ref` also appears here in fault prose that quotes the URL.
  $'scripts/assert-mergeable-head.sh\tbase_ref_path'
  $'scripts/assert-mergeable-head.sh\tbase_ref'
)

allowlisted_hits=()
ref_site_allowlisted() { # $1 = file, $2 = subject
  local entry
  for entry in "${REF_SITE_ALLOWLIST[@]}"; do
    [ "$entry" = "$1"$'\t'"$2" ] || continue
    allowlisted_hits+=("$entry")
    return 0
  done
  return 1
}
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
    py_quote_unshadowed "$file" \
      || fail "$file re-binds 'quote' at module scope; its encoder calls cannot be judged by the stdlib one"
    expression="$(py_encoder_expression "$slice" "$var")"
    if [ -n "$expression" ]; then
      py_encoders=$((py_encoders + 1))
      assert_py_encoder "$label" "$expression" "$kind"
      continue
    fi
    py_hex_constrained "$file" "$slice" "$var" && continue
    ref_site_allowlisted "$file" "$var" && continue
    fail "$label reaches a gh api $kind position without a percent-encoding or a 40-hex constraint in its block"
  fi
  label="$file:$line \$$var"
  jq_arg=""; program=""
  IFS=$'\t' read -r jq_arg program < <(encoder_program "$slice" "$var") || true
  if [ -n "${program:-}" ]; then
    encoders=$((encoders + 1))
    assert_encoder "$label" "$program" "$kind" "$jq_arg"
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
  # The same 40-hex constraint spelled inside the jq program that produced the value.
  # `jq -er` exits non-zero when `select` drops the value, and `set -euo pipefail` at the
  # top of every one of these blocks turns that into an abort, so the constraint is as
  # load-bearing as the `[[ … =~ ]]` form above.
  if grep -qE "^[[:space:]]*$var=\"\\\$\(jq -er .*\^\[0-9a-f\]\{40\}\\\$" <<<"$slice"; then
    continue
  fi
  ref_site_allowlisted "$file" "$var" && continue
  fail "$label reaches a gh api $kind position without a percent-encoding or a 40-hex constraint in its block"
done < <(ref_sites)

# Floors, not targets. They exist so that a recognizer regression -- an anchor dropped, a
# grep that stops matching -- shows up as "the scan stopped reaching the repository" rather
# than as a quieter green run. Raise them when the recognizer widens; never lower one to
# accommodate a scan that found less.
[ "$sites" -ge 70 ] || fail "the ref-interpolation scan found only $sites sites; it is not reaching the repository"
[ "$encoders" -ge 16 ] || fail "only $encoders encoder expressions were exercised; the semantics check is not reaching the fixed sites"
[ "$py_sites" -ge 18 ] || fail "the ref-interpolation scan found only $py_sites Python sites; it is not reaching the Python callers"
[ "$py_encoders" -ge 6 ] || fail "only $py_encoders Python encoder calls were exercised; the semantics check is not reaching them"

# A stale allowlist entry is a silent hole: it would keep vouching for a site that has
# moved, been renamed, or been fixed, and would quietly cover a future site that happens to
# reuse the name. Every entry must have been consulted by a live site.
for entry in "${REF_SITE_ALLOWLIST[@]}"; do
  printf '%s\n' "${allowlisted_hits[@]:-}" | grep -qxF "$entry" \
    || fail "stale ref-site allowlist entry, no site matched it: ${entry//$'\t'/ }"
done

echo "PASS: $sites ref interpolations ($py_sites of them Python) across ${#scanned[@]} workflows"
echo "      and non-test scripts are percent-encoded or 40-hex-constrained, and all $encoders jq"
echo "      and $py_encoders Python encoder expressions keep '/' literal in a query value and"
echo "      encode it as %2F in a path segment"
echo "      ${#REF_SITE_ALLOWLIST[@]} sites are allowlisted with a stated reason instead"
