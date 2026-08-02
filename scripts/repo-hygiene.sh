#!/usr/bin/env bash
# Baseline repository hygiene: every Verjson repository's default branch must
# carry a root README.md that answers what the repository is for, who owns it,
# and how to validate it locally (Verjson/.github#232, ADR 0045).
set -uo pipefail

mode="${REPO_HYGIENE_MODE:-audit}"
root="${REPO_HYGIENE_ROOT:-$PWD}"
ref="${REPO_HYGIENE_REF:-HEAD}"
repository="${REPO_HYGIENE_REPOSITORY:-}"

# The register is resolved next to THIS script, i.e. inside the central
# repository the workflow checks out at a pinned ref — never inside the tree
# being checked. That is what makes an exemption a reviewed grant rather than a
# claim the audited repository makes about itself.
exemptions="${REPO_HYGIENE_EXEMPTIONS:-$(cd "$(dirname "$0")/.." && pwd)/docs/repo-hygiene/exemptions.tsv}"
today="${REPO_HYGIENE_TODAY:-$(date -u +%F)}"

# The only classes an exemption may claim. An unrecognised class is not a
# narrower exemption, it is an unreviewed one — so it exempts nothing.
EXEMPT_CLASSES='archived mirror generated bootstrap'

# Deliberately low: one real sentence. The check enforces that each question was
# ANSWERED, not that the answer is good — judging quality is review's job, and a
# high floor would only teach people to pad. See ADR 0045.
MIN_SECTION_CHARS=40

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --repo-root) root="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --repository) repository="${2:-}"; shift 2 ;;
    *) printf 'repo-hygiene: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

finding() { printf 'repo-hygiene: %s\n' "$1" >&2; }

# A fault is not a verdict. `mode` governs how loudly a POLICY finding lands;
# it never softens "the check could not run", because a check that reports
# success when it cannot read the tree stops working without anyone noticing.
die() { printf 'repo-hygiene: %s\n' "$1" >&2; exit 2; }

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

  while IFS=$'\t' read -r reg_repo reg_class reg_review_by reg_reason; do
    case "${reg_repo:-}" in ''|'#'*) continue ;; esac
    case " $EXEMPT_CLASSES " in
      *" ${reg_class:-} "*) ;;
      *) die "exemption register row for ${reg_repo} claims class '${reg_class:-}', which is not one of: $EXEMPT_CLASSES" ;;
    esac
    [ -n "${reg_review_by:-}" ] && [ -n "${reg_reason:-}" ] \
      || die "exemption register row for ${reg_repo} is missing a review-by date or a reason"
    [ "$reg_repo" = "$repository" ] || continue

    # An exemption that never expires is an exemption nobody re-reads. Past its
    # review-by date the row stops exempting and the check applies again — the
    # backlog re-surfaces instead of being permanently forgotten.
    if [ "$today" \> "$reg_review_by" ]; then
      finding "the $reg_class exemption for $repository lapsed on $reg_review_by — renew it in docs/repo-hygiene/exemptions.tsv or seed a README"
      break
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
[ -z "$readme_path" ] || readme="$(git -C "$root" show "$ref:$readme_path" 2>/dev/null)"

findings=0
if [ -z "$readme_path" ]; then
  finding "$root has no root README.md in the tree at $ref"
  findings=1
elif [ -z "$(printf '%s' "$readme" | tr -d '[:space:]')" ]; then
  # Reported apart from "no sections" on purpose: an empty file and a file that
  # answers none of the questions need different remediation, and the audit
  # backlog is only useful if it says which one this is.
  finding "$root/$readme_path is not a non-empty README (ADR 0045)"
  findings=1
else
  # Topic detection is heading-based and alias-driven: the policy asks that the
  # three questions be ANSWERED, not that a house wording be copied. Aliases are
  # the documented list in ADR 0045 — widen them there, never here alone.
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
            /^#+[ \t]+/ { collecting = (tolower($0) ~ re) ? 1 : 0; next }
            collecting { print }
          ' \
        | grep -viE "^[[:space:]]*[-*>[:space:]]*(todo|tbd|t\.b\.d\.|n\/a|na|none|coming soon|fill (this )?in|\.\.\.|xxx)[[:punct:][:space:]]*$" \
        | tr -d '[:space:]'
    )"

    if [ -z "$body" ]; then
      finding "README.md has no $topic section with a real answer under it (ADR 0045)"
      findings=$((findings + 1))
    elif [ "${#body}" -lt "$MIN_SECTION_CHARS" ]; then
      finding "README.md's $topic section is under $MIN_SECTION_CHARS characters of substance (ADR 0045)"
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
  finding "$findings hygiene finding(s) — see ADR 0045 for the required sections"
  exit 1
fi
printf 'repo-hygiene: audit mode — %d finding(s) reported, not enforced (ADR 0045).\n' "$findings"
exit 0
