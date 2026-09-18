#!/usr/bin/env bash
# A consumer that stops reading before the producer stops writing gives the
# producer EPIPE, and it dies on SIGPIPE. Under `set -o pipefail` — which every
# contract test here sets — that 141 becomes the pipeline's status, and an
# assertion reports a contract violation that never happened
# (Verjson/.github#1430).
#
# `grep -q` was the consumer that first cost a diagnosis, but it was never the
# hazard: *early exit on the read end of a pipe* is. This guard therefore covers
# the consumer class, not one spelling of it — `grep -q`/`--quiet`,
# `grep -m`/`--max-count`, every `head` (`head`, `head -1`, `head -n1`,
# `head -n 1`, `head -c N`), and an `awk` program that calls `exit`
# (Verjson/.github#1445).
#
# It is timing-dependent, so it is invisible on an idle machine and surfaces on a
# loaded self-hosted runner: the original report measured 425 spurious failures in
# 9000 iterations of one assertion under load, and 0 in 200 unloaded. A required
# check that reddens for a reason the diff cannot cause is the ADR 0185 hazard —
# it teaches reviewers to re-run rather than read.
#
# The remedy is to stop truncating the pipe. For `grep -q`, drop `-q` and
# redirect: without it `grep` must read to EOF, so the producer never sees EPIPE.
# For a consumer that genuinely wants only the first line or the first N bytes,
# the producer's output goes to a file first (`producer >"$tmp/out"`, then read
# the file) or the read is bounded without a pipe at all
# (`IFS= read -r first < <(producer)`). Both keep the same result and neither
# closes the read end early.
#
# A here-string — `grep -q pat <<<"$x"`, `head -3 <<<"$out"` — is not a pipe, and
# is unaffected.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# (a) The mechanism itself, deterministically. A producer that matches on its
# first line and then writes more than a pipe can hold makes the failure certain
# rather than probable, so this pins the behavior the scan below exists to
# prevent — without a stress loop whose runtime would depend on runner load.
#
# The `-q` is assembled rather than written, so the scan in (b) does not have to
# exempt this file and thereby stop covering it.
q='q'
# The same trick, for the consumers added by #1445: the positive shapes below are
# written through these so the scan in (b) keeps covering this file rather than
# exempting it and thereby stopping.
h='h'
m='m'
ex='ex'

# The payload after the match is a megabyte, far past any pipe buffer, so the
# producer MUST block until the consumer reads it. `grep -q` has already left,
# so the write fails every time, on every scheduler. Sleeping instead would make
# this guard's own reliability depend on runner load — the very property it
# exists to remove from the suite.
producer() {
  printf 'match\n'
  head -c $((1024 * 1024)) /dev/zero | tr '\0' 'x'
  printf '\n'
}

# The status the hazard produces is platform-dependent and must not be pinned:
# where the producer dies on the signal, pipefail reports 141; where bash
# handles EPIPE in a builtin `printf` instead, the producer returns 1 and
# pipefail reports that. Both are false verdicts, and 1 is the worse of the two
# — it is indistinguishable from an honest "pattern not found". What the
# assertion pins is the lie itself: a non-zero status for a pattern that is
# genuinely present, which the next assertion proves is present.
status=0
( set -o pipefail; producer | grep -"$q" '^match$' ) || status=$?
if [ "$status" -ne 0 ]; then
  pass "grep -${q} makes a still-writing producer fail the pipeline (status $status) despite the match"
else
  fail "the grep -${q} pipeline reported success; the hazard has changed shape and this guard no longer describes it"
fi

status=0
( set -o pipefail; producer | grep '^match$' >/dev/null ) || status=$?
if [ "$status" -eq 0 ]; then
  pass "the redirected form reads to EOF and reports the match honestly"
else
  fail "the redirected form reported $status instead of a clean match"
fi

# A non-match must still be a non-match: the remedy may not weaken the assertion
# it replaces.
status=0
( set -o pipefail; producer | grep '^absent$' >/dev/null ) || status=$?
if [ "$status" -eq 1 ]; then
  pass "the redirected form still reports a genuine non-match as 1"
else
  fail "the redirected form reported $status for a non-match instead of 1"
fi

# (b) No tracked shell script may reintroduce the shape. `git ls-files` is the
# boundary on purpose: it is exactly what Actions checks out, so an untracked
# scratch file cannot redden the check and a tracked one cannot hide from it.
# The pathspec is every tracked `*.sh` rather than `scripts/*.sh`, because the
# composite actions under `.github/actions/` ship shell too and a guard that
# stops at one directory stops guarding the moment a script moves.
#
# `.github/workflows` is deliberately out of scope: the same shape lives in
# generated `run:` blocks that reach ~95 adopters through the generated set, so
# changing them is a release-train change tracked separately (#1431). The frozen
# conformance regression fixtures must not be edited at all. That arm is
# forward-proofing rather than load-bearing today — no tracked file under
# `scripts/ci-gate/conformance/` currently ends in `.sh`.
#
# `scripts/gen-changelog-caller.sh` is excluded for the same reason, and the
# exclusion is load-bearing rather than cosmetic: three of its occurrences are
# emitted verbatim into the generated adopter artifact
# `changelog-contract.test.sh`, so fixing them here changes generated bytes in
# every adopter and fails `required-checks-audit.test.sh` with
# `generated-contract-byte-drift`. They belong to #1431's regeneration at a new
# contract SHA, not to this flake fix.

# A trailing-pipe continuation — `producer |`, newline, `  grep -q ...` — is the
# dominant style in this repo (62 lines across 13 scripts), and a line-at-a-time
# pattern cannot see it: the pipe and the consumer are never on one line. Joining
# continuations first is what makes the scan describe the hazard rather than one
# of its spellings. A trailing backslash is joined for the same reason.
#
# Comment lines are dropped rather than buffered. Without that, a comment ending
# in `|` splices onto the following line and manufactures an offender out of
# prose — a tracked file whose comment reads `# see foo |` above a perfectly safe
# `grep -q pat somefile` would be reported as a reintroduced pipe-fed site, at
# the comment's line number. Dropping them also matches bash, which skips a
# comment between a trailing `|` and the command that continues the pipeline.
join_continuations() {
  awk '
    /^[[:space:]]*#/ { next }
    { buf = buf $0 }
    /(\||\\)[[:space:]]*$/ { if (!start) start = FNR; next }
    { print (start ? start : FNR) ":" buf; buf = ""; start = 0 }
    END { if (buf != "") print (start ? start : FNR) ":" buf }
  ' "$1"
}

# `-q` is one spelling of the hazard, not the hazard, and neither is `grep`.
# `grep -E -q`, `grep --quiet`, `egrep -q`, `grep -m1`, `head -n1`, and
# `awk 'NR==1{print;exit}'` all close the read end early, and a command or
# environment prefix (`LC_ALL=C grep -q`, `command head -1`, `timeout 5 grep -q`)
# changes nothing about that. The pattern therefore matches the consumer class on
# the read end of a pipe. The grep arm is assembled from "$q" so this file need
# not exempt itself from its own scan.
#
# `head` is matched with any arguments and with none, because that is the honest
# description: bare `head` is `head -n 10` and stops after ten lines exactly as
# `head -n1` stops after one. `head -c` is included for the same reason — it is a
# byte budget, not a reason to keep reading.
#
# The ceiling is deliberate and worth stating:
#   * `[ef]?grep` declines to match `zgrep`, `rg`, or a longer identifier ending
#     in `grep`, and only the three command prefixes above are recognized, so
#     `xargs grep -q` and `sudo grep -q` are misses.
#   * `sed`'s `q` command exits early too, and #1445 asked for an explicit
#     decision on it. It is deliberately NOT matched: no tracked shell script in
#     this tree pipes into a quitting `sed` today, while a line pattern cannot
#     tell the `q` *command* in `sed -n '1p;q'` from a `q` inside a replacement
#     or a regex, so the arm would buy a hypothetical catch with real false
#     positives on prose. Revisit it the first time a quitting `sed` is written
#     on the read end of a pipe.
#   * `awk` is matched on a literal `exit` in its program, so an `exit` reached
#     only in a branch that never fires still reads as an offender. That is the
#     safe direction to be wrong in, and the remedy is cheap either way.
# Widening further speculatively would trade false negatives for false positives.
pipe_prefix='(^|[^|])\|[[:space:]]*(![[:space:]]*)?'
pipe_prefix="$pipe_prefix"'([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|command[[:space:]]+|env[[:space:]]+|timeout[[:space:]]+[^[:space:]]+[[:space:]]+)*'
early_grep='[ef]?grep([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-[A-Za-z]*['"$q"'m][A-Za-z0-9]*|--('"$q"'uiet|max-count))'
early_head='head([[:space:]]|$)'
early_awk='awk[^|]*[^[:alnum:]_]exit([^[:alnum:]_]|$)'
pipe_into_early_exit="$pipe_prefix"'('"$early_grep"'|'"$early_head"'|'"$early_awk"')'

scan_file() {
  join_continuations "$1" | grep -E "$pipe_into_early_exit" | sed "s|^|$1:|"
}

scan="$tmp/offenders"
scanned="$tmp/scanned"
: >"$scanned"
(
  cd "$repo_root" || exit 2
  git ls-files -z -- '*.sh' \
    | while IFS= read -r -d '' file; do
        case "$file" in
          */conformance/*|scripts/gen-changelog-caller.sh) continue ;;
        esac
        printf '%s\n' "$file" >>"$scanned"
        scan_file "$file" || true
      done
) >"$scan" 2>"$tmp/scan-err"

# An empty enumeration would satisfy the emptiness test below while reading
# nothing at all, so the count is part of the assertion, not a guard in front
# of it.
scanned_count="$(wc -l <"$scanned")"
if [ -s "$tmp/scan-err" ]; then
  fail "the scan could not run: $(head -1 "$tmp/scan-err")"
elif [ "$scanned_count" -lt 50 ]; then
  fail "the scan enumerated only $scanned_count script(s); it is not covering the tree"
elif [ -s "$scan" ]; then
  fail "$(wc -l <"$scan") pipe-fed early-exiting consumer site(s) reintroduced; see #1430 and #1445"
  sed 's/^/       /' "$scan" >&2
else
  pass "none of the $scanned_count tracked shell scripts pipes into an early-exiting consumer"
fi

# (c) The scan must be able to see every shape it claims to cover. A pattern that
# matched only the one spelling someone happened to write first would pass (b)
# vacuously while the next regression walked straight through it. Each positive
# is checked through `scan_file`, the same path (b) uses, not against the raw
# pattern — the continuation case is invisible without the joiner.
missed=""
check_shape() {
  printf '%s\n' "$2" >"$tmp/shape.sh"
  scan_file "$tmp/shape.sh" >/dev/null 2>&1 || missed="$missed $1"
}
check_shape basic          "awk '{print}' f | grep -$q pat"
check_shape continuation   "$(printf 'producer |\n  grep -%s pat' "$q")"
check_shape separated-flag "producer | grep -E -$q pat"
check_shape long-option    "producer | grep --${q}uiet pat"
check_shape env-prefix     "producer | LC_ALL=C grep -$q pat"
check_shape command-prefix "producer | command grep -$q pat"
check_shape timeout-prefix "producer | timeout 5 grep -$q pat"
check_shape egrep          "producer | egrep -$q pat"
check_shape backslash-join "$(printf 'producer \\\n  | grep -%s pat' "$q")"
check_shape grep-max-count "producer | grep -${m}1 pat"
check_shape grep-max-long  "producer | grep --${m}ax-count=1 pat"
check_shape head-bare      "producer | ${h}ead"
check_shape head-short-num "producer | ${h}ead -1 | cut -d: -f1"
check_shape head-n-joined  "producer | ${h}ead -n1"
check_shape head-n-spaced  "producer | ${h}ead -n 1"
check_shape head-bytes     "producer | ${h}ead -c 65536"
check_shape head-prefixed  "producer | command ${h}ead -n1"
check_shape head-continued "$(printf 'producer |\n  %sead -n 1' "$h")"
check_shape awk-exit       "producer | awk 'NR==1{print;${ex}it}'"
check_shape awk-exit-match "producer | awk '/^object /{print \$2; ${ex}it}'"
if [ -z "$missed" ]; then
  pass "the scan detects every offending shape it claims to cover"
else
  fail "the scan pattern misses:$missed — so (b) proves less than it reports"
fi

# The safe forms must stay safe: a guard that reddened on `grep -q file` or on a
# here-string would be reverted within a week, and the remedy this fix applied
# 39 times must not itself read as an offender.
caught=""
check_safe() {
  printf '%s\n' "$2" >"$tmp/safe.sh"
  scan_file "$tmp/safe.sh" >/dev/null 2>&1 && caught="$caught $1"
}
check_safe file-argument "grep -$q pat somefile"
check_safe here-string   "grep -$q pat <<<\"\$x\""
check_safe the-remedy    "producer | grep pat >/dev/null"
check_safe head-file     "${h}ead -n1 somefile"
check_safe head-heredoc  "head -3 <<<\"\$out\""
check_safe head-redirect "head -n1 <\"\$tmp/out\""
check_safe awk-no-exit   "producer | awk '{print \$2}'"
check_safe grep-m-file   "grep -${m}1 pat somefile"
check_safe exit-elsewhere "producer | cat; exit 1"
if [ -z "$caught" ]; then
  pass "the scan leaves the non-piped and remedied forms alone"
else
  fail "the scan flags safe form(s):$caught"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d test(s) failed.\n' "$fails" >&2
  exit 1
fi
