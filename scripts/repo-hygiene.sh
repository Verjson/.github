#!/usr/bin/env bash
# Baseline repository hygiene: every Verjson repository's default branch must
# carry a root README.md that answers what the repository is for, who owns it,
# and how to validate it locally (Verjson/.github#232, ADR 0046).
set -uo pipefail

# A fault is not a verdict: `mode` governs how loudly a POLICY finding lands;
# it never softens "the check could not run".
die() { printf 'repo-hygiene: %s\n' "$1" >&2; exit 2; }

# Shape alone is not a date: `9999-99-99` matches YYYY-MM-DD but is not a day,
# and the lapse test is a lexicographic compare, so it would grant a permanent
# exemption. Round-tripping through `date` rejects it and normalises nothing —
# `2027-1-1` fails too, which keeps the register's column unambiguous.
valid_date() {
  [ -n "${1:-}" ] && [ "$(date -u -d "$1" +%F 2>/dev/null)" = "$1" ]
}

mode="${REPO_HYGIENE_MODE:-audit}"
root="${REPO_HYGIENE_ROOT:-$PWD}"
ref="${REPO_HYGIENE_REF:-HEAD}"
repository="${REPO_HYGIENE_REPOSITORY:-}"

# The register is resolved next to THIS script, i.e. inside the central
# repository the workflow checks out at a pinned ref — never inside the tree
# being checked. That is what makes an exemption a reviewed grant rather than a
# claim the audited repository makes about itself.
exemptions="${REPO_HYGIENE_EXEMPTIONS:-$(cd "$(dirname "$0")/.." && pwd)/docs/repo-hygiene/exemptions.tsv}"
today="${REPO_HYGIENE_TODAY:-$(date -u +%F 2>/dev/null || true)}"
# An empty `today` makes every lapse test false, so nothing would ever expire —
# fail-open on the one invariant the register is here to keep.
valid_date "$today" \
  || die "could not determine today's date (got '${today}') — failing closed"

# The only classes an exemption may claim. An unrecognised class is not a
# narrower exemption, it is an unreviewed one — so it exempts nothing.
EXEMPT_CLASSES='archived mirror generated bootstrap'

# Deliberately low: one real sentence. The check enforces that each question was
# ANSWERED, not that the answer is good — judging quality is review's job, and a
# high floor would only teach people to pad. See ADR 0046.
# Counted as BYTES under a pinned locale: `${#body}` is characters under a
# UTF-8 locale and bytes under C, so an unpinned locale makes the same README
# pass on one runner and fail on another.
export LC_ALL=C
MIN_SECTION_CHARS=40

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode|--repo-root|--ref|--repository)
      # `shift 2` with one argument left fails WITHOUT shifting, so the loop
      # would spin forever on a trailing flag. Name the fault instead.
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --mode) mode="$2" ;;
        --repo-root) root="$2" ;;
        --ref) ref="$2" ;;
        --repository) repository="$2" ;;
      esac
      shift 2 ;;
    *) printf 'repo-hygiene: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

finding() { printf 'repo-hygiene: %s\n' "$1" >&2; }

# A fault is not a verdict. `mode` governs how loudly a POLICY finding lands;
# it never softens "the check could not run", because a check that reports
# success when it cannot read the tree stops working without anyone noticing.

# `git show <ref>:README.md` cannot distinguish "no such file" from "no such
# repository" by output alone, so resolve the tree first and treat an
# unresolvable one as a fault.
case "$mode" in
  audit|enforce) ;;
  *) die "unknown mode '$mode' — expected 'audit' or 'enforce'" ;;
esac

if [ -n "$repository" ]; then
  # A register that will not resolve means the central checkout is missing or was
  # renamed. Treating that as "nobody is exempt" would fail every exempt repo
  # while looking like a working check, so name the fault instead.
  [ -r "$exemptions" ] \
    || die "could not read the exemption register at $exemptions — failing closed"

  # `|| [ -n ... ]` so a final row with no trailing newline is still read: `read`
  # returns non-zero there, and dropping the row would silently withdraw a
  # granted exemption rather than reporting anything.
  lapsed=false
  while IFS=$'\t' read -r reg_repo reg_class reg_review_by reg_reason || [ -n "${reg_repo:-}" ]; do
    case "${reg_repo:-}" in ''|'#'*) continue ;; esac
    case " $EXEMPT_CLASSES " in
      *" ${reg_class:-} "*) ;;
      *) die "exemption register row for ${reg_repo} claims class '${reg_class:-}', which is not one of: $EXEMPT_CLASSES" ;;
    esac
    [ -n "${reg_review_by:-}" ] && [ -n "${reg_reason:-}" ] \
      || die "exemption register row for ${reg_repo} is missing a review-by date or a reason"
    # Shape-checked, not just present: the lapse test below is a lexicographic
    # string compare, so `never` or `9999-99-99` would grant a permanent
    # exemption and quietly void the review-by invariant this register exists for.
    valid_date "$reg_review_by" \
      || die "exemption register row for ${reg_repo} has review-by '${reg_review_by}', which is not a YYYY-MM-DD date"
    [ "$reg_repo" = "$repository" ] || continue

    # An exemption that never expires is an exemption nobody re-reads. Past its
    # review-by date the row stops exempting and the check applies again — the
    # backlog re-surfaces instead of being permanently forgotten.
    if [ "$today" \> "$reg_review_by" ]; then
      finding "the $reg_class exemption for $repository lapsed on $reg_review_by — renew it in docs/repo-hygiene/exemptions.tsv or seed a README"
      # `continue`, not `break`: the rest of the register still has to be
      # validated, or a malformed row after a lapsed one is never seen.
      lapsed=true
      continue
    fi
    printf 'repo-hygiene: %s is exempt (%s, review by %s): %s\n' \
      "$repository" "$reg_class" "$reg_review_by" "$reg_reason"
    exit 0
  done <"$exemptions"
fi

git -C "$root" rev-parse --verify --quiet "$ref^{tree}" >/dev/null 2>&1 \
  || die "could not read the tree at $ref in $root — failing closed"

# The tree a merge would produce, not the diff that produces it: a PR that
# deletes README.md leaves no added line to inspect, but the resulting tree has
# no README — which is the thing the policy is actually about.
#
# Root entries only, and matched the way GitHub picks a README to render (case
# variants of `readme`, optionally `.md`/`.markdown`). Insisting on the exact
# spelling `README.md` would report a finding a reader cannot reproduce: their
# `readme.md` renders perfectly on the repository's front page.
readme_path="$(
  git -C "$root" ls-tree "$ref" 2>/dev/null \
    | awk '$2 == "blob" { sub(/^[^\t]*\t/, ""); print }' \
    | grep -iE '^readme(\.md|\.markdown)?$' \
    | head -n 1
)"

readme=''
if [ -n "$readme_path" ]; then
  # A resolved path whose blob will not read is the tree being unreadable, not a
  # README that fails the policy — reporting it as a finding would let it pass in
  # audit mode.
  readme="$(git -C "$root" show "$ref:$readme_path" 2>/dev/null)" \
    || die "could not read $readme_path at $ref in $root — failing closed"
fi
# Markdown is line-oriented here; a CRLF checkout would otherwise leave a
# trailing \r that stops every heading from matching its alias.
readme="${readme//$'\r'/}"

findings=0
if [ -z "$readme_path" ]; then
  finding "$root has no root README.md in the tree at $ref"
  findings=1
elif [ -z "$(printf '%s' "$readme" | tr -d '[:space:]')" ]; then
  # Reported apart from "no sections" on purpose: an empty file and a file that
  # answers none of the questions need different remediation, and the audit
  # backlog is only useful if it says which one this is.
  finding "$root/$readme_path is not a non-empty README (ADR 0046)"
  findings=1
else
  # Topic detection is heading-based and alias-driven: the policy asks that the
  # three questions be ANSWERED, not that a house wording be copied. Aliases are
  # the documented list in ADR 0046 — widen them there, never here alone.
  for topic in purpose ownership validation; do
    case "$topic" in
      purpose) alias_re='purpose|overview|what (is|it is|this is|it does|this does)|about|introduction' ;;
      ownership) alias_re='owner|owners|ownership|maintainer|maintainers|contact|contacts|support|team' ;;
      validation) alias_re='local (validation|development|dev|setup|checks?)|develop(ing|ment) locally|running locally|run locally|validation|validating|usage|getting started|build and test|testing|tests?|operations?|running (it|the tests)' ;;
    esac

    # Body = the lines between this topic's heading and the next heading of any
    # level. A placeholder token is not a body: "TODO" under "## Ownership" is
    # the unseeded state #232 exists to catch.
    body="$(
      printf '%s\n' "$readme" \
        | awk -v re="^#+[ \t]+($alias_re)([ \t]|:|$)" '
            # tolower() rather than gawk IGNORECASE: mawk is the default awk on
            # Ubuntu runners, and IGNORECASE is a silent no-op there — the
            # section would never match and every repo would look non-compliant.
            BEGIN { fence = 0; fence_char = ""; fence_len = 0; comment = 0; collecting = 0; level = 0 }
            {
              s = $0
              # A heading inside an HTML comment renders as nothing, so it
              # answers nothing. Without this, a README whose entire body is
              # commented out passes with zero visible content.
              if (comment) {
                c = index(s, "-->")
                if (c == 0) next
                comment = 0
                s = substr(s, c + 3)
              }
              # Same for a fenced block: `# Purpose` in a shell example is a
              # shell comment, not a section heading.
              #
              # This runs BEFORE the "<!--" scan and AFTER the open-comment
              # branch above, and that order is the behaviour on both sides.
              # Scanning for comments first let an unterminated `<!--` inside a
              # fenced HTML example open a comment that ran to end of file, so a
              # compliant README parsed as empty and reported no purpose
              # section. Tracking fences first instead would let a ``` line
              # inside an open comment toggle a fence; the branch above consumes
              # that line before this one sees it.
              #
              # CommonMark closes a fence only with a run of the SAME character
              # at least as long as the one that opened it. Toggling on any
              # fence line read the inner ``` of a ```` block as the close, and
              # everything after it as rendered headings — so a README whose
              # whole body is one code block reported compliant (#352).
              # Measured character by character rather than with a {3,} match:
              # mawk is the default awk on Ubuntu runners, and interval
              # expressions are not something to depend on there.
              t = s
              sub(/^[ \t]*/, "", t)
              ch = substr(t, 1, 1)
              n = 0
              if (ch == "`" || ch == "~") { while (substr(t, n + 1, 1) == ch) n++ }
              if (n < 3) n = 0
              if (fence) {
                # A closing fence carries no info string, so trailing text keeps
                # the block open.
                if (n > 0 && ch == fence_char && n >= fence_len \
                    && substr(t, n + 1) ~ /^[ \t]*$/) fence = 0
                next
              }
              if (n > 0) { fence = 1; fence_char = ch; fence_len = n; next }
              while ((o = index(s, "<!--")) > 0) {
                rest = substr(s, o + 4)
                c = index(rest, "-->")
                if (c > 0) { s = substr(s, 1, o - 1) substr(rest, c + 3) }
                else { s = substr(s, 1, o - 1); comment = 1; break }
              }
              if (s ~ /^#+[ \t]+/) {
                match(s, /[^#]/); n = RSTART - 1
                if (tolower(s) ~ re) { collecting = 1; level = n }
                # Only a heading at the SAME level or shallower ends the
                # section. A `### Goals` under `## Purpose` is part of the
                # purpose answer, not the end of it.
                else if (collecting && n <= level) { collecting = 0 }
                next
              }
              if (collecting) print s
            }
          ' \
        | grep -viE "^[[:space:]]*[-*>[:space:]]*(todo|tbd|t\.b\.d\.|n\/a|na|none|coming soon|fill (this )?in|\.\.\.|xxx)[[:punct:][:space:]]*$" \
        | tr -d '[:space:]'
    )"

    if [ -z "$body" ]; then
      finding "README.md has no $topic section with a real answer under it (ADR 0046)"
      findings=$((findings + 1))
    elif [ "${#body}" -lt "$MIN_SECTION_CHARS" ]; then
      finding "README.md's $topic section is under $MIN_SECTION_CHARS characters of substance (ADR 0046)"
      findings=$((findings + 1))
    fi
  done
fi

if [ "$findings" -eq 0 ]; then
  echo "repo-hygiene: the root README.md answers purpose, ownership, and local validation."
  exit 0
fi

if [ "$mode" = enforce ]; then
  # Exit 1 is a policy verdict; exit 2 (die) is a fault. Keeping them apart lets
  # a rollout dashboard tell "this repo needs a README" from "the check broke".
  finding "$findings hygiene finding(s) — see ADR 0046 for the required sections"
  exit 1
fi
printf 'repo-hygiene: audit mode — %d finding(s) reported, not enforced (ADR 0046).\n' "$findings"
exit 0
