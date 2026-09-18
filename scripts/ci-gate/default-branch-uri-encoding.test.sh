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
#   * Composite actions. `scanned` covers `.github/workflows/*.yml`, `scripts/*.sh` and
#     `scripts/*.py`; `.github/actions/*/action.yml` is NOT in it, so the adopter-facing
#     `commits/${HEAD_SHA}/status` read in `.github/actions/ci-eligibility/action.yml` is
#     never judged here. What covers it is `scripts/ci-gate/ci-eligibility.test.sh:55-63`,
#     which asserts byte parity between that composite script and node-ci's inline copy:
#     the guard this scan proves on the inline copy is the same bytes. That is an indirect
#     proof and it holds only while the parity assertion does.
#   * The sites in REF_SITE_ALLOWLIST -- exempted by hand, each with its reason. An
#     entry that cites a guard pins that guard's literal text, and `guard_is_live` then
#     asks whether that guard still FAILS. What it asks depends on the language:
#       - shell (a workflow `run:` block or a `.sh` script): continuations are joined
#         first -- a trailing `\`, a trailing `&&`/`||`/`|`, and a multi-line `|| { … }`
#         branch are one command -- and the tail that follows the pinned text must match
#         an ALLOW-LIST of shapes that leave the guard. Anything else -- `|| true`,
#         `|| :`, `||:`, `|| { :; }`, `|| echo skipped`, `| cat`, a trailing `&`,
#         `|| exit 0`, a bare `&&` chain with no `||` -- reads as disarmed. The allow-list
#         direction is the point: the denylist this replaced named four literals and six
#         other swallows walked straight past it (#1464 re-review).
#
#         The shapes are, exactly: an empty tail, which under `set -euo pipefail` means the
#         guard's own status is the command's; or, immediately after the final `&&`/`||`,
#         `exit N`/`return N` for N in 1-255, `fail`/`fault`/`die`/`abort …`, or a `{ … }`
#         whose body is FLAT and one of whose top-level statements is exactly one of those
#         actions. `continue` and `break` are NOT on it, in or out of a loop (see below).
#         "Exactly one of those statements" is the part that matters, and it is the second
#         thing this pin got wrong: matching the action as a SUBSTRING of the brace body is a denylist wearing
#         an allow-list's clothes, and `|| { echo "would exit 1 here"; }`,
#         `|| { ( exit 1 ); }`, `|| { false && exit 1; }`, `|| { cat <<EOF` / `exit 1`,
#         `|| exit 256`, `|| return 256`, `|| continue` and `|| break` all matched it and
#         all leave the guard standing (third #1464 re-review).
#         Quoted spans, `#` comments, `${…}`, `$(…)` and `(…)` subshells are blanked by
#         `shell_structure` before the split, so none of them can supply the action.
#
#         What that costs, all of it fail-CLOSED -- a live guard can read as disarmed here,
#         and none of these lets a swallow through:
#           · `exit 300` really does leave the guard (44), but the status is bounded to
#             1-255 because that bound is easier to state than "not a multiple of 256".
#           · a nested command group, or a redirection operator, in the brace body is not
#             flattened and reads as disarmed.
#           · an action reached only through a `&&`/`||` chain inside the body is not
#             unconditionally reached. This anchor does not evaluate conditions, so it
#             cannot tell `{ false && exit 1; }` from `{ [ -n "$x" ] && exit 1; }`; both
#             read as disarmed.
#           · `shell_structure` is a lexical scan, not a shell parser. It models quotes,
#             backticks, backslashes, `${…}`, `$(…)` and word-position `#`, and nothing
#             else -- not here-documents, not `case` patterns, not quoting nested inside
#             `$(…)`. Where it is unsure it blanks, which reads as NOT fatal.
#           · `continue`/`break` are rejected outright rather than modelled. They leave a
#             guard only inside a loop, the lexical `do`/`done` count that established that
#             was ~60 lines whose last real site #1466 rewrote into an `elif`, and in
#             `slice` mode a lone `do` -- in prose, or in a here-document body -- licensed
#             them for the whole slice after it. Rejecting them is fail-closed; the count
#             was not (#1464 re-review round 4).
#       - Python: the comment check and NOTHING MORE. Every cited Python guard is a
#         sub-expression of an `if … is None:` or `require(…)`, and there is no single
#         tail shape that means "this raises" without parsing the file. `SHA.fullmatch(x)`
#         is judged by still being written, not by still failing. Five of the eleven
#         allowlist entries are in this weaker class, and so is the shell-shaped proof
#         that is really a pinned assertion STRING inside a `.py` list. The one
#         Python-shaped denylist literal that used to be here, `or True`, was dropped
#         rather than kept: see `py_guard_is_live` for why a one-entry denylist is worse
#         than an honest gap.
#     Even at its strongest this is a COMMAND-level anchor, not reachability analysis, and
#     these are the ways a pin is satisfied by something that no longer guards:
#       · a guard MOVED into a branch that never runs;
#       · a guard made vacuous by editing the value it tests rather than the test itself;
#       · a terminating word redefined as a no-op. The helper names are allow-listed BY
#         NAME with no proof that they terminate, and bash lets `exit` and `return` be
#         shadowed by a function too, so this covers the whole allow-list, not just
#         `fault`.
#       · for a guard spent as the NEGATED condition of an `if`/`elif`, the pinned USE is
#         taken to be the last record of the input. In `slice` mode that is exact, because
#         `block_slice` cuts the file at the use's own line; in `whole` mode -- an allowlist
#         entry's pinned guard, read from a whole file -- there is no use to cut at, so the
#         END OF THE FILE stands in for it, and a file that happens to end inside the `else`
#         arm reads as protecting a use that may be anywhere, including in another file. No
#         allowlist entry is written that way today, and this is the only fail-OPEN in that
#         class after round 4; every shape listed under `negated_branch_dominates` is now
#         rejected.
#       · that same proof is positional, not dataflow: it establishes that the use LINE is
#         inside the protected arm, not that the value reaching the use is the value the
#         guard tested. A re-assignment between the guard and the use, or a different
#         variable on the use's line, still reads as protected.
#       · the pinned literal matched inside a STRING rather than as a command. The literal
#         search runs over raw text, so deleting a guard and leaving its text in an `echo`
#         or a heredoc satisfies the pin. (In `.py` files one allowlist entry is honestly
#         a pinned assertion string; in shell it is a residual, not a design.)
#     So read the shell pin as "the cited text is still written outside a comment, and the
#     continuation immediately following it is one of the shapes listed above" -- NOT as
#     "the guard still fails", which is what the first three versions of this sentence
#     claimed and could not support. Read the Python pin as "the cited check is still
#     written", and nothing beyond that.
# The recognized-site count is pinned in RECOGNIZED_REF_SITES for the same reason the
# allowlist is explicit: moving an interpolation out of a recognized shape is a way to
# lose coverage without losing a green run.
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
# `.github/actions/*/action.yml` is NOT scanned -- see the composite-action bullet in the
# ceiling above for what covers `ci-eligibility`'s copy of the same read instead.
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

# Bash runs a command, not a source line, and a command is not a run of characters either.
# Three separate things have to be established before a tail can be judged:
#
#   1. Which physical lines make up one command. A guard split with a trailing `\`, or
#      chained with a trailing `&&`/`||`/`|`, or opening a `|| { … }` branch, carries its
#      failure handling on a LATER line: a per-line anchor reads the pinned text on one
#      line and never sees the `|| true` on the next. That is the hole that let node-ci's
#      continuation-form head-sha guard be neutered while this test stayed green (#1464).
#   2. Which characters of that command are shell STRUCTURE and which are data. `exit 1`
#      inside a double-quoted `echo` argument is not a command; neither is one inside a
#      `$(…)`, a `${…}`, or a comment. `shell_structure` blanks those spans, so every
#      structural decision below reads command text only.
#   3. For a guard spent as the negated condition of an `if`/`elif`, where the arms of that
#      construct begin and end, because the proof is then the use's POSITION rather than the
#      guard's own tail. That is `negated_branch_dominates`, below.
#
# `shell_structure` is a lexical scan, not a shell parser: it tracks quotes, `${…}`,
# `$(…)`, backticks, backslashes, and word-position `#`, and nothing else. Where it is
# unsure it blanks, which makes an unrecognized construct read as NOT fatal.
SHELL_STRUCTURE_AWK='
function shell_structure(s,   out, i, n, c, q, d) {
  n = length(s); out = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; out = out " "; continue }
    if (c == "\x27" || c == "\"" || c == "`") { q = c; out = out " "; continue }
    # A backslash escapes the next character -- unless it is the last one on the line,
    # where it is the continuation marker the joiner below looks for.
    if (c == "\\") { if (i < n) { out = out "  "; i++ } else { out = out "\\" }; continue }
    # `${…}` and `$(…)`/`$((…))` are data, and their braces and parens are not grouping.
    if (c == "$" && i < n && substr(s, i + 1, 1) == "{") {
      d = 0
      for (; i <= n; i++) {
        if (substr(s, i, 1) == "{") d++
        else if (substr(s, i, 1) == "}") { d--; if (d == 0) break }
      }
      out = out " "; continue
    }
    if (c == "$" && i < n && substr(s, i + 1, 1) == "(") {
      d = 0
      for (; i <= n; i++) {
        if (substr(s, i, 1) == "(") d++
        else if (substr(s, i, 1) == ")") { d--; if (d == 0) break }
      }
      out = out " "; continue
    }
    # `#` opens a comment only in word position. A `#` inside a word (`release#1`) does
    # not, and neither does one inside quotes, which the branch above already consumed.
    if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[[:space:];&|()]/)) break
    out = out c
  }
  return out
}
function brace_delta(st,   i, n, c, d) {
  d = 0; n = length(st)
  for (i = 1; i <= n; i++) { c = substr(st, i, 1); if (c == "{") d++; else if (c == "}") d-- }
  return d
}
'

shell_structure() { # $1 = shell text -> the same text with data spans blanked
  awk "$SHELL_STRUCTURE_AWK"'{ print shell_structure($0) }' <<<"$1"
}

# Emits one logical line per command. A brace branch is closed by BRACE DEPTH, not by a bare `}` line: a
# closer carrying a tail (`} >&2`, `} || true`) used to leave the state machine open and
# buffer the whole remainder of the file into a single line, and a nested `}` used to
# close the body early -- both fail-closed, but both turn an unrelated edit above a guard
# into an inscrutable false positive (#1464 re-review).
#
# An unterminated branch at end of input drops the buffer -- fail-closed either way, but
# it must not be emitted as a joined line, because that line's "tail" is the rest of the
# file. `whole` (the default) also reports it on stderr; `slice` does not, because a block
# slice legitimately cuts a file mid-branch and that is not a defect in the file.
logical_lines() { # $1 = whole|slice; reads text on stdin, emits one logical line per command
  awk -v mode="${1:-whole}" "$SHELL_STRUCTURE_AWK"'
    { line = $0; sub(/[[:space:]]+$/, "", line); st = shell_structure(line) }
    brace {
      # Inside a brace body a newline IS a statement separator, unless the previous line
      # ended on an operator. Joining with a space would fuse `>&2` and `exit 1` into one
      # statement and hide the fatal one from the allow-list below.
      if (prevst ~ /(\\|&&|\|\||\||&|;|\{|\()[[:space:]]*$/) buf = buf " " line
      else buf = buf "; " line
      prevst = st
      bdepth += brace_delta(st)
      if (bdepth <= 0) { print buf; buf = ""; brace = 0 }
      next
    }
    # A YAML block-scalar introducer (`run: |`) ends in "|" without continuing a command.
    st ~ /:[[:space:]]*\|[-+0-9]*$/ { print buf line; buf = ""; next }
    st ~ /(\|\||&&)[[:space:]]*\{$/ {
      buf = buf line; prevst = st; brace = 1; bdepth = brace_delta(st); next
    }
    st ~ /\\$/ { sub(/\\$/, "", line); buf = buf line; next }
    st ~ /(&&|\|\|)$/ || st ~ /(^|[^|])\|$/ { buf = buf line " "; next }
    { print buf line; buf = "" }
    END {
      if (buf != "" && !brace) print buf
      if (brace) {
        if (mode != "slice") {
          print "logical_lines: unterminated `|| {` branch; the rest of the input was not judged" > "/dev/stderr"
        }
        exit 2
      }
    }
  '
}

# An ALLOW-LIST of what may follow a guard on its own command without disarming it. The
# denylist this replaces named four swallowing literals and missed at least six more --
# `||:`, `|| { :; }`, `|| echo skipped`, `| cat`, a trailing `&`, and `|| exit 0` all kept
# a cited guard reading as live (#1464 re-review). Enumerating swallows is a losing game.
#
# But an allow-list only fails closed if it enumerates SHAPES. Its first form matched the
# fatal action as a SUBSTRING of the brace body, which is a denylist wearing an
# allow-list's clothes: `|| { echo "would exit 1 here"; }`, `|| { ( exit 1 ); }`,
# `|| { false && exit 1; }`, `|| exit 256`, `|| return 256`, `|| continue` and `|| break`
# all matched and all leave the guard (third #1464 re-review).
# So the action must now be a WHOLE top-level statement of a flat brace body, read off the
# structural form, and the status must be a real non-zero wait status.
#
# `return N` is here alongside `exit N` because the gate-rearm receipt guards live inside
# shell functions, where a non-zero return is how the failure leaves the guard.
# `continue`/`break` are NOT here: they leave a guard only inside a loop, and the lexer that
# established loop context was itself a fail-open in `slice` mode (#1464 re-review round 4).
# The four named helpers are this repository's terminating idioms (`fail`, `fault`, `die`,
# `abort`) and are allow-listed BY NAME, not by any proof that they terminate: redefining
# one as a no-op is the same vacuous-guard ceiling the header already states.
#
# The status is bounded to 1-255, the range bash reports unchanged. `exit 256` wraps to 0
# and is a swallow; `exit 300` wraps to 44 and does leave the guard, but is rejected here
# too. That is deliberate: nothing in this repository writes it, and the bound is easier
# to state and to trust than "any N that is not a multiple of 256".
GUARD_FATAL_STATUS='0*([1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
GUARD_FATAL_ACTION="(exit|return)[[:space:]]+${GUARD_FATAL_STATUS}"
GUARD_FATAL_HELPER_NAME='(fail|fault|die|abort)'
GUARD_FATAL_HELPER="${GUARD_FATAL_HELPER_NAME}[[:space:]][^|&]*"

guard_action_leads() { # $1 = structural text -- does it BEGIN fatally?
  [[ "$1" =~ ^[[:space:]]*${GUARD_FATAL_ACTION}([^A-Za-z0-9_]|$) ]] && return 0
  [[ "$1" =~ ^[[:space:]]*${GUARD_FATAL_HELPER} ]]
}

# The brace branch. A body counts only if it is FLAT -- no nested command group -- and one
# of its top-level statements is EXACTLY a fatal action. "Exactly" is what rejects
# `false && exit 1`: a statement reached only through a chain is not unconditionally
# reached, and this anchor does not evaluate conditions. A subshell and a quoted literal
# are already blanked by `shell_structure` before the split.
brace_body_is_fatal() { # $1 = structural text starting just after the opening `{`
  local body="$1" out="" part c i n=${#1} d=1
  for ((i = 0; i < n; i++)); do
    c="${body:i:1}"
    if [ "$c" = '{' ]; then d=$((d + 1))
    elif [ "$c" = '}' ]; then d=$((d - 1)); [ "$d" -eq 0 ] && break
    fi
    out+="$c"
  done
  [ "$d" -eq 0 ] || return 1                      # unbalanced: read as disarmed
  case "$out" in *'{'* | *'}'*) return 1 ;; esac  # a nested group is not a flat body
  # `shell_structure` does not model here-documents, so a heredoc body reads as commands:
  # `|| { cat <<EOF` / `exit 1` / `EOF` / `}` passed as fatal while printing that text.
  # A body containing a redirection operator is not flat either -- read it as disarmed.
  case "$out" in *'<<'*) return 1 ;; esac
  local IFS=';'
  for part in $out; do
    part="${part#"${part%%[![:space:]]*}"}"; part="${part%"${part##*[![:space:]]}"}"
    [[ "$part" =~ ^${GUARD_FATAL_ACTION}$ ]] && return 0
    # The helper's arguments are blanked by `shell_structure` and trimmed off the statement,
    # so match the NAME here rather than the `<name> <args>` form the whole-branch path sees.
    [[ "$part" =~ ^${GUARD_FATAL_HELPER_NAME}([[:space:]]|$) ]] && return 0
  done
  return 1
}

guard_tail_is_fatal() { # $1 = the text following the pinned guard
  # Nothing follows: the command's own non-zero status IS the command's status, and every
  # block this test reads runs under `set -euo pipefail`.
  [[ "$1" =~ ^[[:space:]]*\;?[[:space:]]*$ ]] && return 0
  local struct branch
  struct="$(shell_structure "$1")"
  # Anchored at the START of the tail, not the end: a guard may sit inside a larger group
  # (`[ -z "$head" ] || { [[ … ]] || return 2; ref_query="?ref=$head"; }`), so what matters
  # is that the continuation IMMEDIATELY following it is fatal, not what trails after that.
  # A leading `&&` chain is skipped because only the element after the FINAL `&&`/`||`
  # escapes `set -e`; `[[ … ]] && foo` with no `||` is therefore NOT fatal and is rejected.
  [[ "$struct" =~ ^[[:space:]]*(\&\&[^\|]*)*\|\|(.*)$ ]] || return 1
  branch="${BASH_REMATCH[2]}"
  branch="${branch#"${branch%%[![:space:]]*}"}"
  case "$branch" in
    '{'*) brace_body_is_fatal "${branch#\{}" ;;
    *) guard_action_leads "$branch" ;;
  esac
}

# A plain literal match for a cited guard is not enough. `grep -qF` finds the text anywhere
# in the file, so commenting the guard out, or appending a swallow to it, left this test
# green while the guard no longer guarded anything -- the same rot one level up. A guard
# counts as live only if its pinned text sits on a logical line that is not commented out
# ahead of it and whose tail is on the fatal allow-list above.
#
# This is a command-level anchor, not a reachability analysis. See the ceiling note in the
# header: a guard MOVED into a branch that never executes still satisfies this.
# A guard may also be spent as the NEGATED condition of an `if`/`elif` whose protected use
# sits in the sibling `else` arm. Nothing follows it on its own command but `; then`, so the
# tail allow-list cannot judge it, and the proof is structural instead: the arm the guard
# opens is the FAILING one, and it cannot fall through to the `else`. Establishing that needs
# lookahead past the guard's own logical line, so the records are read into an array rather
# than streamed.
#
# Deliberately narrow, and fail-closed on everything else. A positive `if <guard>; then <use>`
# is NOT accepted: its failing arm is the one that reaches the rest of the file. A negated
# branch with no `else` is not accepted either, for the same reason.
branch_events() { # $1 = structural text -> its command-position if/fi/else/elif, in order
  local st="$1" part
  st="${st//&&/;}"; st="${st//||/;}"; st="${st//|/;}"; st="${st//&/;}"
  local IFS=';'
  for part in $st; do
    part="${part#"${part%%[![:space:]]*}"}"; part="${part%%[[:space:]]*}"
    case "$part" in if | fi | else | elif) printf '%s\n' "$part" ;; esac
  done
}

guard_opens_negated_branch() { # $1 = text before the guard, $2 = text after it
  [[ "$1" =~ ^[[:space:]]*(el)?if[[:space:]]+\![[:space:]]*$ ]] || return 1
  [[ "$2" =~ ^[[:space:]]*\;?[[:space:]]*then[[:space:]]*$ ]]
}

# One top-level statement of the `then` arm, judged by the SAME two notions the tail
# allow-list uses -- no third idea of what "terminates" means, and in particular `exit 0` is
# not one of them here either.
arm_statement_is_fatal() { # $1 = structural text of one top-level `then`-arm statement
  local st="${1#"${1%%[![:space:]]*}"}"
  case "$st" in
    '{'*) brace_body_is_fatal "${st#\{}" ;;
    *) guard_action_leads "$st" ;;
  esac
}

# Walk forward from the guard's logical line to the PINNED USE, which is the LAST record of
# the input: `block_slice` cuts the file at the use's own line, so in `slice` mode the end of
# the records is the use itself. Relative depth 0 is the construct the guard opened.
#
# Existence of an `else` is NOT the question, and answering it was this anchor's own
# fail-open (#1464 re-review round 4): seven shapes had one and still ran the use with an
# unchecked value -- a non-terminating `then` arm with the use after `fi`, two empty arms, a
# `then` arm of `exit 0`, the use in the `else` AND again after `fi`, the construct inside a
# loop, a `then` arm calling a helper nothing proves terminates, and the `elif` form of the
# first. Worse, it separated two cases that are the same program: a vacuous `else` was
# accepted where the pinned no-`else` fixture below was rejected.
#
# Two things can make the guard protect the use, and both are checked, because neither
# subsumes the other:
#   · the use lies inside the `else`/`elif` EXTENT -- the arm entered only when `! guard`
#     was false. This is how `scripts/privileged-merge-conformance.sh:327` is written, and
#     its `then` arm only counts a failure and falls through, so nothing else establishes it.
#   · the `then` arm TERMINATES, so a use below `fi` is reached only when the guard held.
#     `if ! guard; then echo …; exit 1; fi` is the ordinary spelling and read as dead before.
# A depth-0 `fi` means the construct closed ABOVE the use, so from there only the second can
# apply. Running out of records still inside the `then` arm proves nothing.
negated_branch_dominates() { # $1 = index of the guard's record in GUARD_RECORDS
  local i d=0 event struct in_then=1 arm_terminates=1 depth_at_start
  for ((i = $1 + 1; i < ${#GUARD_RECORDS[@]}; i++)); do
    struct="$(shell_structure "${GUARD_RECORDS[i]}")"
    depth_at_start=$d
    # Only a statement of the arm ITSELF is unconditionally reached: one nested inside a
    # further branch is not, which is the same reason `{ false && exit 1; }` is rejected.
    if [ "$in_then" -eq 1 ] && [ "$depth_at_start" -eq 0 ] \
      && arm_statement_is_fatal "$struct"; then
      arm_terminates=0
    fi
    while IFS= read -r event; do
      case "$event" in
        if) d=$((d + 1)) ;;
        # `arm_terminates` is already 0-for-yes, so it IS the answer below the construct.
        fi) [ "$d" -eq 0 ] && return "$arm_terminates"; d=$((d - 1)) ;;
        else | elif) [ "$d" -eq 0 ] && in_then=0 ;;
      esac
    done < <(branch_events "$struct")
  done
  # The records ran out without closing the construct. Inside the `else`/`elif` arm that is
  # the use sitting in the protected extent; still inside the `then` arm it proves nothing.
  [ "$in_then" -eq 0 ]
}

guard_live_literal() { # $1 = literal proof text, $2 = whole|slice; reads the text on stdin
  local -a GUARD_RECORDS=()
  local line i
  mapfile -t GUARD_RECORDS < <(logical_lines "${2:-whole}")
  for ((i = 0; i < ${#GUARD_RECORDS[@]}; i++)); do
    line="${GUARD_RECORDS[i]}"
    case "$line" in *"$1"*) ;; *) continue ;; esac
    # Anything opening a comment ahead of the pinned text disarms the whole line.
    case "${line%%"$1"*}" in *'#'*) continue ;; esac
    guard_tail_is_fatal "${line#*"$1"}" && return 0
    guard_opens_negated_branch "${line%%"$1"*}" "${line#*"$1"}" || continue
    negated_branch_dominates "$i" && return 0
  done
  return 1
}

guard_live_re() { # $1 = ERE whose match is the proof, $2 = whole|slice; reads the text on stdin
  local -a GUARD_RECORDS=()
  local line match i
  mapfile -t GUARD_RECORDS < <(logical_lines "${2:-whole}")
  for ((i = 0; i < ${#GUARD_RECORDS[@]}; i++)); do
    line="${GUARD_RECORDS[i]}"
    [[ "$line" =~ $1 ]] || continue
    match="${BASH_REMATCH[0]}"
    case "${line%%"$match"*}" in *'#'*) continue ;; esac
    guard_tail_is_fatal "${line#*"$match"}" && return 0
    guard_opens_negated_branch "${line%%"$match"*}" "${line#*"$match"}" || continue
    negated_branch_dominates "$i" && return 0
  done
  return 1
}

# Python has no single tail shape that means "this raises": every cited Python guard is a
# sub-expression of an `if … is None:` test or a `require(…)` call, so there is nothing to
# allow-list without parsing the file. A Python guard therefore gets the comment check and
# NOTHING MORE. This is the weaker of the two anchors, deliberately and visibly so; the
# header's ceiling says which entries it covers.
#
# The denylist this replaced also carried one Python-shaped literal, `or True`. It is NOT
# kept here. A one-entry denylist catches `or True` and nothing adjacent to it -- `or 1`,
# `or (lambda: True)()`, a `require` redefined above -- while reading like protection, and
# that gap is the whole reason the shell side stopped denylisting. Dropping it is a
# deliberate, named loss of one narrow case in exchange for a claim that is true.
py_guard_is_live() { # $1 = file, $2 = literal guard text
  local line
  while IFS= read -r line; do
    case "${line%%"$2"*}" in *'#'*) continue ;; esac
    return 0
  done < <(grep -F -- "$2" "$1")
  return 1
}

guard_is_live() { # $1 = file, $2 = literal guard text
  if [ "${1##*.}" = py ]; then
    py_guard_is_live "$1" "$2"
    return
  fi
  guard_live_literal "$2" <"$1"
}

# A 40-hex-constrained value needs no encoding: the constraint already excludes every
# character that could change the meaning of the URL. Three spellings count, and in a shell
# file each is held to the same liveness rule as a cited guard -- this is the anchor for the
# head-sha constraint #1464 added to node-ci, so it may not be the weaker of the two.
#
# In a `.py` file the shell-shaped proof may be a pinned assertion STRING rather than a
# command (`scripts/cli-projects-package-surface-ruleset.py:169` is one), whose tail is
# Python list punctuation and never a `||` continuation. Those get the comment check only,
# the same weaker anchor `py_guard_is_live` applies, and the header ceiling says so.
sha_constrained() { # $1 = variable name, $2 = block slice, $3 = the file it came from
  local var="$1"
  if [ "${3##*.}" = py ]; then
    grep -qF "[[ \"\$$var\" =~ ^[0-9a-f]{40}\$ ]]" <<<"$2" && return 0
    grep -qE "(^|[[:space:]])$var[:=][[:space:]]*[\"']?[0-9a-f]{40}[\"']?[[:space:]]*\$" <<<"$2" && return 0
    grep -qE "^[[:space:]]*$var=\"\\\$\(jq -er .*\^\[0-9a-f\]\{40\}\\\$" <<<"$2" && return 0
    return 1
  fi
  guard_live_literal "[[ \"\$$var\" =~ ^[0-9a-f]{40}\$ ]]" slice <<<"$2" && return 0
  guard_live_re "(^|[[:space:]])$var[:=][[:space:]]*[\"']?[0-9a-f]{40}[\"']?([[:space:]]|\$)" slice <<<"$2" && return 0
  # The same 40-hex constraint spelled inside the jq program that produced the value.
  # `jq -er` exits non-zero when `select` drops the value, and `set -euo pipefail` at the
  # top of every one of these blocks turns that into an abort, so the constraint is as
  # load-bearing as the `[[ … =~ ]]` form above -- provided the assignment itself is not
  # the thing that swallows, which is why the match runs to the closing `)"`.
  guard_live_re "^[[:space:]]*$var=\"[\$][(]jq -er .*\^\[0-9a-f\][{]40[}][\$].*[)]\"" slice <<<"$2" && return 0
  return 1
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
  # Redirected, not pipe-fed: `grep -q` exits on its first match and would SIGPIPE a
  # still-writing producer (#1430, #1445).
  grep -qxF "$expected" < <( ( root="$tmp/fx"; scanned=("$name"); ref_sites ) | cut -f3,4 ) \
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

# The guard-liveness anchor's own coverage. Every `dead` tail below kept a cited guard
# reading as live while it no longer failed (#1464 re-review): the anchor used to carry a
# DENYLIST of four swallowing literals, and `||:`, `|| { :; }`, `|| echo skipped`, `| cat`,
# a trailing `&`, and `|| exit 0` all walked past it. Enumerating swallows is a losing
# game, so the anchor now allow-lists the tails that DO fail and rejects everything else.
# These cases run against synthetic files, so fixing a real guard cannot retire one.
HEX_GUARD='[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]'

guard_tail_case() { # $1 = live|dead, $2 = label, $3… = the guard's physical lines
  local expect="$1" label="$2"; shift 2
  printf '%s\n' "$@" >"$tmp/fx/guard.sh"
  if guard_is_live "$tmp/fx/guard.sh" "$HEX_GUARD"; then
    [ "$expect" = live ] || fail "the cited-guard anchor accepted a disarmed guard: $label"
  else
    [ "$expect" = dead ] || fail "the cited-guard anchor rejected a live guard: $label"
  fi
  # The inline 40-hex proof reads the same shapes out of a block slice, and the two must
  # not disagree: the guard this PR added to node-ci is judged by the inline path.
  if sha_constrained head_sha "$(printf '%s\n' "$@")" "$tmp/fx/guard.sh"; then
    [ "$expect" = live ] || fail "the inline 40-hex proof accepted a disarmed guard: $label"
  else
    [ "$expect" = dead ] || fail "the inline 40-hex proof rejected a live guard: $label"
  fi
}

guard_tail_case live 'a same-line `|| { …; exit 1; }`' \
  "$HEX_GUARD"' || { echo "::error::current PR head is unavailable"; exit 1; }'
guard_tail_case live 'the line-continuation form node-ci uses' \
  "$HEX_GUARD"' \' \
  '  || { echo "::error::head-sha is not a 40-hex object name"; exit 1; }'
guard_tail_case live 'an && chain closing in `|| exit 1`' \
  "$HEX_GUARD"' &&' \
  '  [[ "$head_sha" != /* ]] || exit 1'
guard_tail_case dead 'the guard commented out' \
  '# '"$HEX_GUARD"' || { echo "::error::x"; exit 1; }'
guard_tail_case dead 'a `|| true` on the continuation line, not the pinned one' \
  "$HEX_GUARD"' \' \
  '  || true'
for swallow in '|| true' '|| :' '||:' '|| { :; }' '|| echo skipped' '| cat' '&' '|| exit 0'; do
  guard_tail_case dead "a \`$swallow\` tail" "$HEX_GUARD $swallow"
done

# The rest of the fatal allow-list, pinned so a later narrowing cannot drop a shape this
# repository actually writes -- and its near-misses, pinned so widening it stays deliberate.
guard_tail_case live 'a `|| return 2` inside a function' \
  "$HEX_GUARD"' || return 2'
guard_tail_case live 'a guard nested in a larger group, fatal branch first' \
  '[ -z "$head_sha" ] || { '"$HEX_GUARD"' || return 2; ref_query="?ref=$head_sha"; }'
guard_tail_case live 'a `|| fault …` named terminating helper' \
  "$HEX_GUARD"' || fault 1 "could not resolve a head SHA"'
guard_tail_case live 'a multi-line `|| {` failure branch' \
  "$HEX_GUARD"' || {' \
  '  echo "::error::could not resolve a head SHA" >&2' \
  '  exit 1' \
  '}'
# A guard spent as the NEGATED condition of an `if`/`elif`, whose protected use sits in the
# sibling `else`. Nothing follows the guard on its own command but `; then`, so the fatal-tail
# allow-list above cannot see it -- and main's #1466 rewrote
# `scripts/privileged-merge-conformance.sh:327` from a `|| { …; continue; }` into exactly this
# shape, which made this scan report a live guard as dead at four call sites (#1464 re-review
# round 4). The domination is structural: the failing arm cannot fall through to the `else`.
# Each fixture ENDS at the use, because `block_slice` does: it cuts the file at the use's
# own line, so the closing `fi` of a construct the use sits inside is not in the slice. A
# fixture that trails a `fi` past the use would be asking a different question.
guard_tail_case live 'a negated `elif` whose protected use is in the `else`' \
  'if [ "${#pins[@]}" -ne 1 ]; then' \
  '  failures=$((failures + 1))' \
  'elif ! '"$HEX_GUARD"'; then' \
  '  failures=$((failures + 1))' \
  'else' \
  '  gh api "repos/$repository/commits/$head_sha"'
guard_tail_case live 'a negated `if` whose protected use is in the `else`' \
  'if ! '"$HEX_GUARD"'; then' \
  '  failures=$((failures + 1))' \
  'else' \
  '  gh api "repos/$repository/commits/$head_sha"'
# The other way the guard reaches a use: the `then` arm leaves, so a use BELOW `fi` runs
# only when the guard held. This ordinary spelling read as dead until round 4.
guard_tail_case live 'a negated `if` whose `then` arm exits, with the use after `fi`' \
  'if ! '"$HEX_GUARD"'; then' \
  '  echo "::error::head sha is not a 40-hex object name" >&2' \
  '  exit 1' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
# Fail-closed boundaries of that shape, pinned so widening it stays deliberate. Without an
# `else` the failing arm falls straight through to the use, so the branch proves nothing.
guard_tail_case dead 'a negated `if` with no `else`, which falls through to the use' \
  'if ! '"$HEX_GUARD"'; then' \
  '  echo "::warning::head sha looks wrong"' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
# ... and neither does giving that same program a VACUOUS `else`. Accepting it while
# rejecting the fixture directly above was this anchor's round-4 fail-open: the two are the
# same program, and an `else` that exists is not an `else` the use is in. The shapes below
# are the distinct mechanisms behind the seven that got through; `if`-with-non-terminating-
# arm, two empty arms, and the construct wrapped in a `while` are restatements of the first
# and are not pinned separately.
guard_tail_case dead 'a vacuous `else`, which is the no-`else` program above' \
  'if ! '"$HEX_GUARD"'; then' \
  '  echo "::warning::head sha looks wrong"' \
  'else' \
  '  :' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
guard_tail_case dead 'a negated `elif` whose use is after `fi`, not in the `else`' \
  'if [ -z "$head_sha" ]; then' \
  '  :' \
  'elif ! '"$HEX_GUARD"'; then' \
  '  :' \
  'else' \
  '  :' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
guard_tail_case dead 'a use in the `else` AND again after `fi`, judged at the second' \
  'if ! '"$HEX_GUARD"'; then' \
  '  :' \
  'else' \
  '  gh api "repos/$repository/commits/$head_sha"' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
# The `then` arm has to leave by the SAME notion the tail allow-list uses. `exit 0` is the
# swallow that list rejects, and an unlisted helper name is one nothing here proves
# terminates; accepting either below `fi` would contradict the cases above.
guard_tail_case dead 'a `then` arm of `exit 0`, the swallow the tail allow-list rejects' \
  'if ! '"$HEX_GUARD"'; then' \
  '  exit 0' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
guard_tail_case dead 'a `then` arm calling an unlisted helper, which may return' \
  'if ! '"$HEX_GUARD"'; then' \
  '  notice "head sha looks wrong"' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
guard_tail_case dead 'a negated `if` whose `else` belongs to a nested branch' \
  'if ! '"$HEX_GUARD"'; then' \
  '  if [ -n "$head_sha" ]; then' \
  '    echo "::warning::x"' \
  '  else' \
  '    echo "::warning::y"' \
  '  fi' \
  'fi' \
  'gh api "repos/$repository/commits/$head_sha"'
guard_tail_case dead 'a POSITIVE `if` condition, whose failing arm is the unguarded one' \
  'if '"$HEX_GUARD"'; then' \
  '  gh api "repos/$repository/commits/$head_sha"' \
  'fi'

guard_tail_case dead 'an && chain with no || at all: set -e exempts the failing element' \
  "$HEX_GUARD"' && echo ok'
guard_tail_case dead 'an unlisted helper name, which nothing here proves terminates' \
  "$HEX_GUARD"' || notice "head sha looks wrong"'
guard_tail_case dead 'a `|| { … }` branch whose body never leaves' \
  "$HEX_GUARD"' || { echo "::warning::head sha looks wrong"; }'

# The allow-list's SECOND fail-open, and the reason the brace branch is no longer a
# substring match over the body (third #1464 re-review). Every tail below matched
# `[{][^}]*[^A-Za-z_](exit|return)[[:space:]]+[1-9][0-9]*…[}]` and every one of them
# leaves the guard standing. An allow-list that does not reason about command position is
# a denylist wearing an allow-list's clothes, so these are pinned permanently.
guard_tail_case dead 'a `exit 1` that is only ever echoed, never run' \
  "$HEX_GUARD"' || { echo "would exit 1 here"; }'
guard_tail_case dead 'an `exit 1` that leaves a subshell and nothing else' \
  "$HEX_GUARD"' || { ( exit 1 ); }'
guard_tail_case dead 'an `exit 1` that is unreachable behind a false `&&`' \
  "$HEX_GUARD"' || { false && exit 1; }'
# Two fail-closed false negatives fixed in the same pass (#1464 re-review round 4): a
# zero-padded status, which bash reports unpadded, and a named terminating helper reached as
# a statement of a brace body rather than as the whole branch.
guard_tail_case live 'an `|| exit 01`, which bash exits 1 from' \
  "$HEX_GUARD"' || exit 01'
guard_tail_case live 'a named terminating helper inside a `|| { … }` body' \
  "$HEX_GUARD"' || { echo "::error::bad pin"; fail "head sha is not a 40-hex object name"; }'
guard_tail_case dead 'an `|| exit 0256`, which still wraps to a 0 wait status' \
  "$HEX_GUARD"' || exit 0256'
guard_tail_case dead 'an `|| exit 256`, which wraps to a 0 wait status' \
  "$HEX_GUARD"' || exit 256'
guard_tail_case dead 'an `|| return 256`, which wraps to a 0 wait status' \
  "$HEX_GUARD"' || return 256'
# `continue`/`break` are not on the allow-list at all, in or out of a loop. They were, and
# the loop-depth lexer that made them safe outside one was ~60 lines whose only remaining
# consumer was its own fixture: main's #1466 rewrote `privileged-merge-conformance.sh:314`,
# the one real site, into an `elif`. Forcing that lexer to report depth 0 everywhere on the
# merged tree failed nothing but those fixtures. Deleting it also deletes the fail-open it
# carried in `slice` mode, where a lone `do` -- in prose, or in a here-document body --
# licensed `continue`/`break` for everything after it in the slice (#1464 re-review round 4).
guard_tail_case dead 'an `|| continue`, whose enclosing loop this anchor does not model' \
  'while IFS= read -r repository; do' \
  '  '"$HEX_GUARD"' || { echo "::error::bad pin"; continue; }' \
  '  gh api "repos/$repository/commits/$head_sha"' \
  'done < <(printf "")'
guard_tail_case dead 'an `|| break`, for the same reason' \
  'for repository in a b; do' \
  '  '"$HEX_GUARD"' || break' \
  'done'
guard_tail_case dead 'an `exit 1` that is only ever printed by a here-document' \
  "$HEX_GUARD"' || {' \
  '  cat <<EOF' \
  'exit 1' \
  'EOF' \
  '}'
guard_tail_case dead 'a nested group in the brace body, which this anchor does not flatten' \
  "$HEX_GUARD"' || {' \
  '  handler() {' \
  '    :' \
  '  }' \
  '  exit 1' \
  '}'

# `logical_lines` closes a `|| {` branch by brace DEPTH. Closing on a bare `}` line alone
# left a closer carrying a tail (`} >&2`, `} || true`) open forever -- buffering the whole
# rest of the file into one logical line -- and let a nested `}` close the body early.
# Both are fail-CLOSED, so neither was a bypass; both turn an unrelated edit anywhere
# above a guard into an inscrutable false positive (#1464 re-review).
guard_tail_case live 'a `} >&2` closer above the guard, which must not swallow the file' \
  'maybe || {' \
  '  echo x' \
  '} >&2' \
  "$HEX_GUARD"' || exit 1' \
  'echo later'
guard_tail_case live 'a nested `}` above the guard, which must not close the branch early' \
  'maybe || {' \
  '  handler() {' \
  '    :' \
  '  }' \
  '  echo x' \
  '}' \
  "$HEX_GUARD"' || exit 1'
# A trailing `\` inside a COMMENT is not a continuation: joining it prefixed the next
# line with `#` and read a live guard as commented out (#1464 re-review).
guard_tail_case live 'a comment ending in a backslash above the guard' \
  '# the head sha is pinned below \' \
  "$HEX_GUARD"' || exit 1'

# An input that ends inside a `|| {` branch drops the buffer rather than emitting it as a
# joined line whose "tail" is the rest of the file. Fail-closed, and in `whole` mode it
# says so on stderr instead of reporting a silent green.
printf '%s\n' "$HEX_GUARD"' || exit 1' 'maybe || {' '  echo x' >"$tmp/fx/guard.sh"
guard_is_live "$tmp/fx/guard.sh" "$HEX_GUARD" 2>/dev/null \
  || fail "a live guard above an unterminated branch was not judged"
printf '%s\n' 'maybe || {' '  echo x' "$HEX_GUARD"' || exit 1' >"$tmp/fx/guard.sh"
guard_is_live "$tmp/fx/guard.sh" "$HEX_GUARD" 2>/dev/null \
  && fail "a guard inside an unterminated branch was judged live"
grep -q 'unterminated' < <(guard_is_live "$tmp/fx/guard.sh" "$HEX_GUARD" 2>&1 >/dev/null) \
  || fail "an unterminated branch was swallowed without saying so"


# A command whose own non-zero status ends the step needs no continuation at all; that is
# how the repo-hygiene entry is written. Swallowing it still has to redden.
BARE_GUARD='resolved="$(git -C .repo-hygiene rev-parse HEAD)"'
printf '%s\n' "$BARE_GUARD" >"$tmp/fx/guard.sh"
guard_is_live "$tmp/fx/guard.sh" "$BARE_GUARD" \
  || fail "the cited-guard anchor rejected a bare command whose own status ends the step"
printf '%s\n' "$BARE_GUARD"' || true' >"$tmp/fx/guard.sh"
guard_is_live "$tmp/fx/guard.sh" "$BARE_GUARD" \
  && fail "the cited-guard anchor accepted a bare command whose failure is swallowed"

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
# below), and a NEW site that is not listed still fails.
#
# An entry is four tab-separated fields:
#
#     file <TAB> subject <TAB> guard-file <TAB> guard-text
#
# and the last two are the part that keeps the record honest. An entry that says "another
# step already constrains this" is a claim about code somewhere else, and that code can be
# edited away while this gate keeps printing PASS -- deleting the 40-hex assert from
# gate-rearm.yml, or the `SHA.fullmatch` from container_deployment_transport.py, used to
# leave this test green. So an entry that cites a guard PINS it: the literal guard text is
# grepped for below, in the idiom scripts/gen-container-deployment.sh uses for its own
# pinned contract text, and removing the guard reddens THIS gate.
#
# Three reason classes appear here, and nothing else should be added without one:
#   sha-guarded  -- the value is a 40-hex object name whose constraint is established in
#                   another step, another function, or at the caller, outside this scan's
#                   block slice. Cites and pins that constraint.
#   sha-supplied -- the value is an object name supplied by GitHub itself, so there is no
#                   repository-local guard to pin; inventing one would be ceremony. Only a
#                   value that never passes through adopter text belongs here.
#   ref          -- the value is a ref name carrying a stated non-encoding guard at its
#                   source.
# --------------------------------------------------------------------------------------
REF_SITE_ALLOWLIST=(
  # sha-supplied: `.headRefOid` from `gh pr view` on the PR this run is gating -- GitHub
  # answers a 40-hex OID or the `// ""` default, and no adopter text reaches it. Nothing
  # repository-local constrains it, so there is nothing to pin: it is here for the same
  # reason node-ci's `github.sha` would be, not because a check lives elsewhere.
  $'.github/workflows/ai-review-merge.yml\thead_sha\t\t'
  # sha-guarded: same value, but gate-rearm asserts the pattern itself, in the job that
  # resolves it -- a different step from the read this scan is looking at.
  $'.github/workflows/gate-rearm.yml\thead_sha\t.github/workflows/gate-rearm.yml\t[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]'
  # sha-guarded: `git rev-parse HEAD` in the checkout this step just made; git answers a
  # 40-hex object name or fails, and the step runs under `set -euo pipefail`.
  $'.github/workflows/repo-hygiene.yml\tresolved\t.github/workflows/repo-hygiene.yml\tresolved="$(git -C .repo-hygiene rev-parse HEAD)"'
  # sha-guarded: validated via `validate_workflow_identity`, whose `re.fullmatch` on the
  # 40-hex pattern lives in that function rather than in `build_receipt`'s own block.
  $'scripts/container_deployment_review_producer.py\targs.producer_commit\tscripts/container_deployment_review_producer.py\tre.fullmatch(r"[0-9a-f]{40}", contract_ref) is None'
  # sha-guarded: `SHA.fullmatch(target['sha'])` on the line above, spelled through
  # `.get()` at the use. Same value, different expression, so the literal match cannot
  # join them up.
  $'scripts/container_deployment_transport.py\ttarget.get(\'sha\')\tscripts/container_deployment_transport.py\tSHA.fullmatch(target[\'sha\'])'
  # sha-guarded: the same pattern inside the probe validator, a different function from
  # the transport call.
  $'scripts/container_deployment_transport.py\tprobe[\'workflowCommit\']\tscripts/container_deployment_transport.py\tSHA.fullmatch(probe[\'workflowCommit\'])'
  # sha-guarded: `hub_tree`'s own parameter. Its two callers pass the literal "main" and a
  # value USES_RE extracted under a 40-hex pattern, so the constraint is at the caller.
  $'scripts/fleet-contract-inventory.py\tref\tscripts/fleet-contract-inventory.py\t(?P<sha>[0-9a-f]{40})'
  # sha-guarded: `require_sha` is the 40-hex boundary check for this value, but it is a
  # call rather than an inline pattern, so the scan cannot read it as one.
  $'scripts/renovate-changelog.py\thead_sha\tscripts/renovate-changelog.py\trequire_sha(planned["head_sha"], "plan.head_sha")'
  # ref: guarded at verify-arm-receipt.sh:59-60 with a charset pattern plus explicit
  # rejection of a leading "/", of "..", and of "//" -- a traversal guard rather than an
  # encoding, which is the one other shape this test accepts by hand. Note that this site
  # interpolates the branch into a `rules/branches/` path with NO encoding at all, which
  # puts it on the literal-slash side of the disagreement recorded below.
  $'scripts/ci-gate/verify-arm-receipt.sh\tarm_base_branch\tscripts/ci-gate/verify-arm-receipt.sh\t[[ "$arm_base_branch" =~ ^[A-Za-z0-9._/-]+$ ]]'
  # ref: DELIBERATE and UNRESOLVED. assert-mergeable-head.sh encodes with `@uri` and then
  # gsubs %2F back to "/", i.e. the QUERY form, into a `rules/branches/` PATH segment,
  # because its comment states the literal separator is what addresses the ruleset.
  #
  # This repository does not agree with itself about that endpoint. FOUR sites build the
  # path form -- gate_coverage_audit.py:210, required-checks-audit.sh:233,
  # required-checks-rollout.sh:233, and scripts/privileged-merge-conformance.sh:92 -- while
  # TWO keep the slash literal: assert-mergeable-head.sh:215 (query form into a path) and
  # scripts/ci-gate/verify-arm-receipt.sh:62 (no encoding at all, above).
  #
  # `branches/` and `commits/` were measured to accept BOTH forms against the live API
  # while widening this scan; `rules/branches/` could not be settled here because no
  # Verjson ruleset targets a slash-bearing ref to compare against, and the endpoint
  # returned zero rules for both forms. Do not "fix" either side on a guess: settling it
  # is tracked in #1470. `base_ref` also appears here in fault prose that quotes the URL.
  $'scripts/assert-mergeable-head.sh\tbase_ref_path\t\t'
  $'scripts/assert-mergeable-head.sh\tbase_ref\t\t'
)

allowlisted_hits=()
ref_site_allowlisted() { # $1 = file, $2 = subject
  local entry entry_file entry_subject
  for entry in "${REF_SITE_ALLOWLIST[@]}"; do
    IFS=$'\t' read -r entry_file entry_subject _ _ <<<"$entry"
    [ "$entry_file" = "$1" ] && [ "$entry_subject" = "$2" ] || continue
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
  sha_constrained "$var" "$slice" "$file" && continue
  ref_site_allowlisted "$file" "$var" && continue
  fail "$label reaches a gh api $kind position without a percent-encoding or a 40-hex constraint in its block"
done < <(ref_sites)

# Floors, not targets. They exist so that a recognizer regression -- an anchor dropped, a
# grep that stops matching -- shows up as "the scan stopped reaching the repository" rather
# than as a quieter green run. Raise them when the recognizer widens; never lower one to
# accommodate a scan that found less.
# Pinned, not slack: a refactor that moves an interpolation OUT of a recognized shape
# -- string concatenation instead of an f-string brace, a `compare/` prefix hoisted
# into its own variable -- lowers this count while every remaining site still
# passes, so a loose floor lets coverage drain away under a green run. Raise it
# deliberately, the way the allowlist is edited; never lower it to accommodate a
# scan that found less.
RECOGNIZED_REF_SITES=77
[ "$sites" -ge "$RECOGNIZED_REF_SITES" ] \
  || fail "the ref-interpolation scan recognized $sites sites, below the pinned $RECOGNIZED_REF_SITES; a ref interpolation moved out of a shape this scan can see"
[ "$encoders" -ge 16 ] || fail "only $encoders encoder expressions were exercised; the semantics check is not reaching the fixed sites"
[ "$py_sites" -ge 18 ] || fail "the ref-interpolation scan found only $py_sites Python sites; it is not reaching the Python callers"
[ "$py_encoders" -ge 6 ] || fail "only $py_encoders Python encoder calls were exercised; the semantics check is not reaching them"

# A stale allowlist entry is a silent hole: it would keep vouching for a site that has
# moved, been renamed, or been fixed, and would quietly cover a future site that happens to
# reuse the name. Every entry must have been consulted by a live site.
for entry in "${REF_SITE_ALLOWLIST[@]}"; do
  # Redirected, not pipe-fed: `grep -q` exits on its first match and would SIGPIPE a
  # still-writing producer (#1430, #1445).
  grep -qxF "$entry" < <(printf '%s\n' "${allowlisted_hits[@]:-}") \
    || fail "stale ref-site allowlist entry, no site matched it: ${entry//$'\t'/ }"

  # An entry that cites a guard pins its literal text, so removing the guard reddens HERE
  # instead of quietly turning the entry into a vouch for a value nothing constrains.
  IFS=$'\t' read -r entry_file entry_subject guard_file guard_text <<<"$entry"
  [ -n "$guard_file" ] || continue
  label="ref-site allowlist entry $entry_file \$$entry_subject"
  [ -f "$root/$guard_file" ] \
    || fail "$label cites a guard file that is missing: $guard_file"
  guard_is_live "$root/$guard_file" "$guard_text" \
    || fail "$label cites a guard that is gone, commented out, or neutered in $guard_file: $guard_text"
done

echo "PASS: $sites ref interpolations ($py_sites of them Python) across ${#scanned[@]} workflows"
echo "      and non-test scripts are percent-encoded or 40-hex-constrained, and all $encoders jq"
echo "      and $py_encoders Python encoder expressions keep '/' literal in a query value and"
echo "      encode it as %2F in a path segment"
echo "      ${#allowlisted_hits[@]} sites are covered by ${#REF_SITE_ALLOWLIST[@]} allowlist entries with a stated reason instead"
