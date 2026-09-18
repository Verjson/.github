#!/usr/bin/env bash
# Differential audit of the canonical `uses:` pin extractor in
# scripts/privileged-merge-conformance.sh.
#
# Widening the capture from `([0-9a-f]{40})` to `([^[:space:]]+)` plus an optional YAML
# comment is not verdict-neutral, and the pull request that made the change published a
# verdict-flip figure three times. A figure that load-bearing has to be re-derivable by
# anyone reading the repository, so the corpus and the comparison live here rather than
# in a throwaway script.
#
# Two properties are asserted, and they age differently:
#
#  * The historical differential -- how the shipped extractor's verdicts differ from the
#    expression at aa9d3865178a52cc2ddade774cd28716fd3ca03d. This pins the published
#    figures. Changing the shipped extractor is meant to redden it and force the numbers
#    to be re-derived rather than restated.
#  * The two-site agreement -- the privileged-merge and promotion-retry sites must extract
#    identically on a name-normalized corpus. That is the property that actually failed:
#    the two sites were duplicated, the retry copy kept the narrow capture and its
#    fail-open, and the drift was found only by reading both. This assertion does not age.
#
# The new expression is read out of the shipped script, never transcribed, so the figures
# cannot drift from the code they describe.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$root/scripts/privileged-merge-conformance.sh"
generator="$root/scripts/gen-privileged-merge-caller.sh"
base_revision=aa9d3865178a52cc2ddade774cd28716fd3ca03d
contract_sha=848c49fd4dac307f26180acd420760a27ceff0ba
second_sha=a6b3ccc0590f4fcfdacd7818279ab3eea6b30155
required_checks='[{"name":"shell-tests","app_id":15368,"workflow_id":315894159,"workflow_path":".github/workflows/actions-ci.yml"}]'
retry_workflow_names='["actions-ci"]'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# The expression as shipped at the base revision, recorded here because an Actions
# checkout is shallow and cannot be relied on to hold that blob. Where the blob *is*
# reachable the record is checked against it rather than trusted.
old_expression_template='s#^[[:space:]]+uses: Verjson/\.github/\.github/workflows/@WF@\.yml@([0-9a-f]{40})[[:space:]]*$#\1#p'

old_pins() { # old_pins <canonical-workflow-basename>  (body on stdin)
  sed -nE "${old_expression_template//@WF@/$1}"
}

# Read the shipped helper out of the audited script and use it verbatim. Extracting the
# text rather than sourcing the script avoids executing the audit, and keeps the
# comparison honest: if the helper is renamed or restructured this fails loudly instead
# of silently comparing a stale transcription.
helper_text="$(awk '/^extract_canonical_pins\(\) \{/,/^\}$/' "$audit")"
if [ -z "$helper_text" ] || ! grep -q 'sed -nE' <<<"$helper_text"; then
  printf 'FAIL - the shipped pin extractor helper could not be read from %s\n' "$audit"
  echo "1 test(s) failed."
  exit 1
fi
eval "$helper_text"
new_pins() { extract_canonical_pins "$1"; }

# --- corpus -------------------------------------------------------------------------
# Each record is `id<TAB>lines<TAB>sed program`, applied to a freshly generated conformant
# caller. `lines` is the number of canonical `uses:` lines the mutation is expected to
# leave, and is asserted rather than assumed -- an earlier re-derivation was wrong because
# a fixture meant to be two lines had collapsed to one. `@WF@`, `@SHA@` and `@SHA2@` are
# substituted so one corpus serves both sites.
#
# Bodies are generated and mutated rather than checked in literally, so this file carries
# no text that reads as a real canonical pin.
corpus=$(cat <<'CORPUS'
conforming	1	
mutable-branch	1	s|@@SHA@$|@main|
mutable-tag	1	s|@@SHA@$|@v1.2.3|
mutable-branch-with-slash	1	s|@@SHA@$|@release/1.x|
short-sha	1	s|@@SHA@$|@848c49f|
uppercase-sha	1	s|@@SHA@$|@848C49FD4DAC307F26180ACD420760A27CEFF0BA|
sha-one-short	1	s|@@SHA@$|@848c49fd4dac307f26180acd420760a27ceff0b|
sha-one-long	1	s|@@SHA@$|@848c49fd4dac307f26180acd420760a27ceff0bad|
sha-with-non-hex	1	s|@@SHA@$|@848c49fd4dac307f26180acd420760a27ceff0bg|
ref-percent	1	s|@@SHA@$|@%|
ref-ampersand	1	s|@@SHA@$|@\&|
ref-backtick	1	s|@@SHA@$|@`id`|
ref-command-substitution	1	s|@@SHA@$|@$(id)|
ref-backreference	1	s|@@SHA@$|@\\1|
ref-quoted-value	1	s|uses: Verjson|uses: "Verjson|;s|@@SHA@$|@main"|
ref-empty	1	s|@@SHA@$|@|
pin-comment-space	1	s|@@SHA@$|@@SHA@ # v1.2.3|
pin-comment-tab	1	s|@@SHA@$|@@SHA@\t# v1.2.3|
pin-comment-multiple-spaces	1	s|@@SHA@$|@@SHA@   # renovate: pinned|
pin-comment-bare-hash	1	s|@@SHA@$|@@SHA@ #|
pin-comment-containing-hash	1	s|@@SHA@$|@@SHA@ # see #1471|
pin-comment-then-trailing-space	1	s|@@SHA@$|@@SHA@ # v1.2.3  |
pin-hash-unseparated	1	s|@@SHA@$|@@SHA@#v1|
pin-trailing-whitespace	1	s|@@SHA@$|@@SHA@   |
mutable-with-comment	1	s|@@SHA@$|@main # pinned by hand|
other-organization	1	s|uses: Verjson/\.github/\.github/workflows/@WF@|uses: Verjson/other/.github/workflows/@WF@|
other-workflow-file	0	s|workflows/@WF@\.yml|workflows/ai-unrelated.yml|
no-leading-indent	1	s|^ *\(uses: Verjson\)|\1|
no-space-after-uses	1	s|uses: Verjson|uses:Verjson|
no-canonical-line	0	s|^ *uses: Verjson/\.github/\.github/workflows/@WF@\.yml@.*$||
conformant-plus-mutable-branch	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2main|
conformant-plus-tag	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2v1.2.3|
conformant-plus-second-sha-with-comment	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2@SHA2@ # v1.2.3|
conformant-plus-same-sha-with-comment	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2@SHA@ # v1.2.3|
conformant-plus-metacharacter-ref	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2%|
two-identical-shas	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2@SHA@\n\1\2@SHA@|
two-mutable-branches	2	s|^\( *\)\(uses: Verjson/\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2main\n\1\2develop|
conformant-plus-other-organization	2	s|^\( *\)\(uses: Verjson/\)\(\.github/\.github/workflows/@WF@\.yml@\).*$|\1\2\3@SHA@\n\1uses: Verjson/other/.github/workflows/@WF@.yml@main|
CORPUS
)

# --- verdict model ------------------------------------------------------------------
# The two arms the extractor feeds, in the order the audited script tests them: the pin
# count first, then the 40-hex guard. Nothing downstream of those arms is modelled, so a
# verdict of `accept` means "reaches the compare API", not "fully conformant".
verdict() { # verdict <pin>...
  if [ "$#" -ne 1 ]; then
    printf 'refuse:pin-count'
  elif [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'accept'
  else
    printf 'refuse:non-sha'
  fi
}

# A tab is IFS whitespace, so an empty field in the table below would collapse when the
# table is read back and silently shift every later column. No field is ever empty.
join_pins() { # join_pins <pin>...
  [ "$#" -gt 0 ] || { printf '<none>'; return 0; }
  local IFS='|'
  printf '%s' "$*"
}

render_shape() { # render_shape <workflow-basename> <sed program>
  local workflow="$1" program="$2" body
  case "$workflow" in
    ai-privileged-merge) body="$(bash "$generator" "$contract_sha" "$required_checks")" ;;
    ai-promotion-retry) body="$(bash "$generator" "$contract_sha" --retry "$retry_workflow_names" "$required_checks")" ;;
  esac
  [ -n "$program" ] || { printf '%s\n' "$body"; return 0; }
  program="${program//@WF@/$workflow}"
  program="${program//@SHA2@/$second_sha}"
  program="${program//@SHA@/$contract_sha}"
  printf '%s\n' "$body" | sed -e "$program"
}

report="$tmp/differential.tsv"
: >"$report"
shape_count=0
line_assertion_failures=""
while IFS=$'\t' read -r id expected_lines program; do
  [ -n "$id" ] || continue
  shape_count=$((shape_count + 1))
  for workflow in ai-privileged-merge ai-promotion-retry; do
    body="$(render_shape "$workflow" "$program")"
    actual_lines="$(grep -c "workflows/$workflow\.yml@" <<<"$body")"
    if [ "$actual_lines" -ne "$expected_lines" ]; then
      line_assertion_failures+="$id/$workflow expected=$expected_lines actual=$actual_lines "
    fi
    mapfile -t before < <(old_pins "$workflow" <<<"$body")
    mapfile -t after < <(new_pins "$workflow" <<<"$body")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$workflow" \
      "$(join_pins "${before[@]}")" "$(join_pins "${after[@]}")" \
      "$(verdict "${before[@]}")" "$(verdict "${after[@]}")" \
      >>"$report"
  done
done <<<"$corpus"

if [ -z "$line_assertion_failures" ]; then
  pass "every corpus shape carries the canonical \`uses:\` line count it declares"
else
  fail "corpus shapes did not render the declared line count: $line_assertion_failures"
fi

# --- the two-site agreement (does not age) ------------------------------------------
mismatched_sites=""
while IFS=$'\t' read -r id workflow before after _ _; do
  case "$workflow" in
    ai-privileged-merge) caller_before="$before"; caller_after="$after" ;;
    ai-promotion-retry)
      [ "$before" = "$caller_before" ] && [ "$after" = "$caller_after" ] \
        || mismatched_sites+="$id "
      ;;
  esac
done <"$report"
if [ -z "$mismatched_sites" ]; then
  pass "the privileged-merge and promotion-retry sites extract identically on every shape"
else
  fail "the two extraction sites disagree, which is the drift this file exists to catch: $mismatched_sites"
fi

# --- the historical differential -----------------------------------------------------
flips=0 accept_to_refuse=0 refuse_to_accept=0 diagnostic_only=0
accept_to_refuse_ids=""
refuse_to_accept_ids=""
while IFS=$'\t' read -r id workflow _ _ before after; do
  [ "$workflow" = ai-privileged-merge ] || continue
  [ "$before" != "$after" ] || continue
  flips=$((flips + 1))
  if [ "$before" = accept ]; then
    accept_to_refuse=$((accept_to_refuse + 1))
    accept_to_refuse_ids+="$id "
  elif [ "$after" = accept ]; then
    refuse_to_accept=$((refuse_to_accept + 1))
    refuse_to_accept_ids+="$id "
  else
    diagnostic_only=$((diagnostic_only + 1))
  fi
done <"$report"

summary="shapes=$shape_count flips=$flips accept_to_refuse=$accept_to_refuse refuse_to_accept=$refuse_to_accept diagnostic_only=$diagnostic_only"

# Print the whole table, not only the totals. The figure is quoted in a changelog fragment
# and a pull request; a reader who wants to check it should be able to check it from the
# run's own output rather than by rebuilding the corpus.
printf '# shape\tsite\tpins_before\tpins_after\tverdict_before\tverdict_after\n'
sed 's/^/# /' "$report"
printf '# %s\n' "$summary"
printf '# accept->refuse: %s\n' "$accept_to_refuse_ids"
printf '# refuse->accept: %s\n' "$refuse_to_accept_ids"

expected_summary='shapes=38 flips=26 accept_to_refuse=5 refuse_to_accept=6 diagnostic_only=15'
if [ "$summary" = "$expected_summary" ]; then
  pass "the published verdict differential is reproduced by the committed corpus"
else
  fail "verdict differential moved: expected '$expected_summary', derived '$summary'"
fi

# --- the recorded base expression ----------------------------------------------------
if git -C "$root" cat-file -e "$base_revision:scripts/privileged-merge-conformance.sh" 2>/dev/null; then
  if git -C "$root" show "$base_revision:scripts/privileged-merge-conformance.sh" \
    | grep -qF -- "${old_expression_template//@WF@/ai-privileged-merge}"; then
    pass "the recorded pre-change expression matches the blob at $base_revision"
  else
    fail "the recorded pre-change expression is not the one shipped at $base_revision"
  fi
else
  pass "pre-change blob is unreachable in this checkout, so the recorded expression stands unchecked"
fi

# --- metacharacters reach sed only as input ------------------------------------------
# All six expressions in the audited script are single-quoted or, in the helper,
# interpolate one script-internal literal; adopter text arrives on stdin. Assert that,
# because the helper is the one place a refactor could turn adopter text into expression
# text.
metacharacter_leak=""
for ref in '%' '&' '`id`' '$(id)' '\1' '\&' 'a%b&c'; do
  body="    uses: Verjson/.github/.github/workflows/ai-privileged-merge.yml@$ref"
  captured="$(new_pins ai-privileged-merge <<<"$body")"
  [ "$captured" = "$ref" ] || metacharacter_leak+="[$ref -> $captured] "
done
if [ -z "$metacharacter_leak" ]; then
  pass "shell and sed metacharacters in a ref are captured literally, never interpreted"
else
  fail "a metacharacter ref was transformed rather than captured: $metacharacter_leak"
fi

grep -q $'\tbash scripts/ci-gate/privileged-merge-pin-extractor-differential.test.sh$' \
  "$root/scripts/actions-ci-groups.tsv" \
  && pass "the pin extractor differential runs in actions CI" \
  || fail "the pin extractor differential is not wired into actions CI"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
