#!/usr/bin/env bash
# Unit tests for scripts/repo-hygiene.sh (Verjson/.github#232, ADR 0046).
#
# Every fixture is a real git repository, and every assertion runs the script
# against a committed tree — the same surface CI checks. Nothing here inspects a
# diff: the policy is about the tree a merge would produce, so a README that a
# PR deletes has to read as absent, not as an unchanged file.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/repo-hygiene.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

# A README that satisfies the documented substance rule: three required topics,
# each with a real answer under it. Reused as the "compliant" baseline so a
# fixture only has to state how it deviates.
compliant_readme() {
  cat <<'MD'
# widget-service

## Purpose

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
}

# fixture <name> [--no-readme] — a committed git repo whose README.md is exactly
# what arrives on stdin. Stdin is streamed rather than captured: `$(cat)` strips
# trailing newlines, which would silently turn a whitespace-only fixture into a
# no-README fixture and leave the empty-README case testing nothing.
fixture() {
  local dir="$tmp/$1"
  local readme=1
  [ "${2:-}" = --no-readme ] && readme=0
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.com
  printf 'placeholder\n' >"$dir/.keep"
  if [ "$readme" -eq 1 ]; then cat >"$dir/README.md"; else cat >/dev/null; fi
  git -C "$dir" add -A
  git -C "$dir" commit -qm fixture
  printf '%s\n' "$dir"
}

# check <root> [extra args...] — run the script in enforce mode over a fixture.
# Enforce is the mode under test for policy verdicts; audit-mode reporting gets
# its own cases below.
check() {
  local root="$1"; shift
  REPO_HYGIENE_ROOT="$root" bash "$script" --mode enforce "$@"
}

# --------------------------------------------------------------------------
# The tree has no root README at all.
# --------------------------------------------------------------------------
missing="$(fixture missing --no-readme </dev/null)"
check "$missing" >"$tmp/missing.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'readme' "$tmp/missing.out"; } \
  && pass "a tree with no root README is a finding" \
  || { fail "missing README accepted or unreported (rc=$rc)"; sed 's/^/diag - /' "$tmp/missing.out"; }

# --------------------------------------------------------------------------
# The README exists but says nothing.
# --------------------------------------------------------------------------
empty="$(fixture empty <<'MD'


MD
)"
check "$empty" >"$tmp/empty.out" 2>&1
rc=$?
# Pinned to the emptiness verdict, not just to a non-zero exit: an empty README
# also has no sections, so a bare `rc != 0` would still pass with the emptiness
# rule deleted, and the case would be documenting nothing.
{ [ "$rc" -ne 0 ] && grep -qi 'non-empty' "$tmp/empty.out"; } \
  && pass "a whitespace-only README is a finding, reported as emptiness" \
  || { fail "empty README accepted or misreported (rc=$rc)"; sed 's/^/diag - /' "$tmp/empty.out"; }

# --------------------------------------------------------------------------
# Substance. A README that is present and non-empty but answers none of the
# three required questions is the case that prompted #232 — a title and a
# placeholder are what an unseeded repository already has.
# --------------------------------------------------------------------------
placeholder="$(fixture placeholder <<'MD'
# widget-service

TODO
MD
)"
check "$placeholder" >"$tmp/placeholder.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a title-and-placeholder README is a finding" \
  || { fail "placeholder README accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/placeholder.out"; }

# --------------------------------------------------------------------------
# The rule has to be satisfiable, or it is not a policy but an outage.
# --------------------------------------------------------------------------
valid="$(compliant_readme | fixture valid)"
check "$valid" >"$tmp/valid.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a README answering all three questions is accepted" \
  || { fail "compliant README rejected (rc=$rc)"; sed 's/^/diag - /' "$tmp/valid.out"; }

# --------------------------------------------------------------------------
# Headings alone are copy-paste. Each required topic needs a real answer under
# it, or the seeded template passes while saying nothing.
# --------------------------------------------------------------------------
stubbed="$(fixture stubbed <<'MD'
# widget-service

## Purpose

TODO

## Ownership

TBD

## Local validation

N/A
MD
)"
check "$stubbed" >"$tmp/stubbed.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "required headings with placeholder bodies are a finding" \
  || { fail "stubbed sections accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/stubbed.out"; }

# --------------------------------------------------------------------------
# Deletion PR. The compliant README is on the base commit and removed on the
# head commit — there is no added line to inspect, and a diff-based check reads
# the PR as touching nothing relevant. The resulting tree has no README.
# --------------------------------------------------------------------------
deleted="$(compliant_readme | fixture deleted)"
git -C "$deleted" rm -q README.md
git -C "$deleted" commit -qm 'chore: drop the README'
check "$deleted" >"$tmp/deleted.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a PR that deletes the README is a finding" \
  || { fail "deletion of the README accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/deleted.out"; }

# The same tree at its parent still passes, which is what proves the case above
# came from the deletion rather than from a fixture that was never compliant.
check "$deleted" --ref HEAD~1 >"$tmp/deleted-base.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "the base commit of the deletion PR is still compliant" \
  || { fail "deletion fixture was never compliant (rc=$rc)"; sed 's/^/diag - /' "$tmp/deleted-base.out"; }

# --------------------------------------------------------------------------
# Fail closed on a broken lookup. A tree the script cannot read is a FAULT, not
# a verdict — and a fault must be loud in BOTH modes. Audit mode exists to keep
# a policy finding from breaking a consumer on day one; it is not a licence to
# report success when the check never ran. A hygiene check that passes when it
# cannot read the tree is one that silently stops working.
# --------------------------------------------------------------------------
notrepo="$tmp/not-a-repo"
mkdir -p "$notrepo"
compliant_readme >"$notrepo/README.md"
REPO_HYGIENE_ROOT="$notrepo" bash "$script" --mode audit >"$tmp/notrepo.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'could not read' "$tmp/notrepo.out"; } \
  && pass "an unreadable tree fails closed as a fault, even in audit mode" \
  || { fail "unreadable tree reported success (rc=$rc)"; sed 's/^/diag - /' "$tmp/notrepo.out"; }

# --------------------------------------------------------------------------
# Audit is the default, so landing this check cannot break a consumer's CI on
# day one. It must still SAY what it found — an audit that reports nothing
# produces no remediation backlog, which is the whole point of the phase.
# --------------------------------------------------------------------------
REPO_HYGIENE_ROOT="$placeholder" bash "$script" >"$tmp/audit.out" 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && grep -qi 'audit' "$tmp/audit.out" && grep -qi 'purpose' "$tmp/audit.out"; } \
  && pass "the default mode audits: findings are reported, exit stays 0" \
  || { fail "default mode is not a reporting audit (rc=$rc)"; sed 's/^/diag - /' "$tmp/audit.out"; }

REPO_HYGIENE_ROOT="$placeholder" bash "$script" --mode nonsense >"$tmp/badmode.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an unrecognised mode is rejected instead of silently auditing" \
  || { fail "unknown mode fell through to a pass (rc=$rc)"; sed 's/^/diag - /' "$tmp/badmode.out"; }

# --------------------------------------------------------------------------
# Exemptions. The register is a tracked file in THIS repository, so granting one
# is a reviewed PR here — never a claim made by the repository being checked.
# Each row: repository, class, review-by date, reason.
# --------------------------------------------------------------------------
register="$tmp/exemptions.tsv"
{
  printf '# repository\tclass\treview-by\treason\n'
  printf 'Verjson/old-thing\tarchived\t2027-01-01\tArchived 2026-05; read-only history.\n'
  printf 'Verjson/upstream-mirror\tmirror\t2027-01-01\tVendor snapshot; upstream owns the README.\n'
  printf 'Verjson/verjson-schema-dist\tgenerated\t2027-01-01\tPublished artefacts only; generator repo documents it.\n'
  printf 'Verjson/new-service\tbootstrap\t2026-09-01\tReserved name; seeded in the next sprint.\n'
} >"$register"

# exempt_check <repository> <root> — audit-mode default, so an exemption that
# only works under enforce would still show up as a day-one finding.
exempt_check() {
  REPO_HYGIENE_ROOT="$2" REPO_HYGIENE_EXEMPTIONS="$register" REPO_HYGIENE_TODAY=2026-08-02 \
    bash "$script" --mode enforce --repository "$1"
}

while IFS=' ' read -r repository class; do
  exempt_check "$repository" "$missing" >"$tmp/exempt-$class.out" 2>&1
  rc=$?
  { [ "$rc" -eq 0 ] && grep -qi "exempt" "$tmp/exempt-$class.out"; } \
    && pass "a registered $class repository is exempt and says so" \
    || { fail "$class exemption not honoured (rc=$rc)"; sed 's/^/diag - /' "$tmp/exempt-$class.out"; }
done <<'CASES'
Verjson/old-thing archived
Verjson/upstream-mirror mirror
Verjson/verjson-schema-dist generated
Verjson/new-service bootstrap
CASES

# An unregistered repository is not exempt, however plausible its name.
exempt_check Verjson/old-thing-2 "$missing" >"$tmp/unregistered.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a repository absent from the register is not exempt" \
  || { fail "unregistered repository treated as exempt (rc=$rc)"; sed 's/^/diag - /' "$tmp/unregistered.out"; }

# The self-assertion hole: a repository that ships its own exemption marker is
# claiming a grant nobody reviewed. Only the central register can exempt.
selfclaim="$(fixture selfclaim --no-readme </dev/null)"
{
  printf 'exempt: true\nclass: archived\nreason: we say so\n' >"$selfclaim/.repo-hygiene-exempt"
  printf 'Verjson/selfclaim\tarchived\t2027-01-01\twe say so\n' >"$selfclaim/exemptions.tsv"
} 2>/dev/null
git -C "$selfclaim" add -A
git -C "$selfclaim" commit -qm 'claim an exemption'
exempt_check Verjson/selfclaim "$selfclaim" >"$tmp/selfclaim.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a repository cannot exempt itself with an in-tree marker" \
  || { fail "self-asserted exemption honoured — that is a bypass (rc=$rc)"; sed 's/^/diag - /' "$tmp/selfclaim.out"; }

# A lapsed row stops exempting, so the backlog re-surfaces instead of being
# permanently forgotten under a grant nobody re-read.
REPO_HYGIENE_ROOT="$missing" REPO_HYGIENE_EXEMPTIONS="$register" REPO_HYGIENE_TODAY=2026-09-02 \
  bash "$script" --mode enforce --repository Verjson/new-service >"$tmp/lapsed.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'laps' "$tmp/lapsed.out"; } \
  && pass "an exemption past its review-by date stops exempting" \
  || { fail "lapsed exemption still honoured (rc=$rc)"; sed 's/^/diag - /' "$tmp/lapsed.out"; }

# A register the script cannot make sense of is a fault. Reading it as "nobody is
# exempt" would be quietly wrong for the exempt repos; reading it as "skip the
# register" would be quietly wrong for everyone else.
malformed="$tmp/malformed.tsv"
printf 'Verjson/old-thing\tdeprecated\t2027-01-01\tclass nobody agreed to\n' >"$malformed"
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$malformed" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --mode audit --repository Verjson/anything >"$tmp/malformed.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'deprecated' "$tmp/malformed.out"; } \
  && pass "an unrecognised exemption class is a fault, not a narrower exemption" \
  || { fail "unknown exemption class passed silently (rc=$rc)"; sed 's/^/diag - /' "$tmp/malformed.out"; }

incomplete="$tmp/incomplete.tsv"
printf 'Verjson/old-thing\tarchived\t\t\n' >"$incomplete"
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$incomplete" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --mode audit --repository Verjson/old-thing >"$tmp/incomplete.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "an exemption without a reason and a review-by date is rejected" \
  || { fail "undocumented exemption accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/incomplete.out"; }

# A register path that does not resolve means the central checkout is missing or
# renamed. Silently exempting nobody would look like a working check.
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$tmp/no-such-register.tsv" \
  bash "$script" --mode audit --repository Verjson/old-thing >"$tmp/noregister.out" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qi 'register' "$tmp/noregister.out"; } \
  && pass "a missing exemption register is a fault, not an empty one" \
  || { fail "missing register treated as no exemptions (rc=$rc)"; sed 's/^/diag - /' "$tmp/noregister.out"; }

# --------------------------------------------------------------------------
# The shipped artefacts, not just the logic.
# --------------------------------------------------------------------------

# The register that actually ships must parse under the same fail-closed rules
# as the fixtures above — a malformed row committed here would fault every
# consumer at once.
REPO_HYGIENE_ROOT="$valid" bash "$script" --mode enforce --repository Verjson/not-registered \
  >"$tmp/register.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "the committed exemption register parses under the shipped rules" \
  || { fail "the committed register is malformed or missing (rc=$rc)"; sed 's/^/diag - /' "$tmp/register.out"; }

# Correct construction: the README a new repository is seeded with must satisfy
# the policy it is seeded to satisfy. A template that fails the check teaches
# every new repo to start non-compliant.
template="$repo_root/docs/repo-hygiene/README.template.md"
if [ -f "$template" ]; then
  seeded="$(fixture seeded <"$template")"
  check "$seeded" >"$tmp/template.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] \
    && pass "the seeded template README satisfies the policy it seeds" \
    || { fail "the template README does not pass the check (rc=$rc)"; sed 's/^/diag - /' "$tmp/template.out"; }
else
  fail "no seeded README template at docs/repo-hygiene/README.template.md"
fi

# This repository is a Verjson repository too, and it is the one that publishes
# the rule. Dogfooding it here is what keeps the rule honest about being usable.
check "$repo_root" >"$tmp/self.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "this repository's own README satisfies the rule it publishes" \
  || { fail "the publishing repository fails its own hygiene check (rc=$rc)"; sed 's/^/diag - /' "$tmp/self.out"; }

# --------------------------------------------------------------------------
# Edge cases.
# --------------------------------------------------------------------------

# Root means root. A repository with rich docs under docs/ and nothing at the
# top level is exactly the "where do I start?" case #232 is about.
nested="$(fixture nested --no-readme </dev/null)"
mkdir -p "$nested/docs"
compliant_readme >"$nested/docs/README.md"
git -C "$nested" add -A
git -C "$nested" commit -qm 'document under docs/'
check "$nested" >"$tmp/nested.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a README under docs/ does not satisfy the root requirement" \
  || { fail "nested README accepted as the root README (rc=$rc)"; sed 's/^/diag - /' "$tmp/nested.out"; }

# GitHub renders `readme.md` and `Readme.md` as the repository README, so the
# check must too — otherwise it reports a finding a reader cannot reproduce.
lowercase="$(compliant_readme | fixture lowercase)"
git -C "$lowercase" mv README.md readme.md
git -C "$lowercase" commit -qm 'lowercase the filename'
check "$lowercase" >"$tmp/lowercase.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a lowercase readme.md is the README, as GitHub renders it" \
  || { fail "case variant of README.md reported as missing (rc=$rc)"; sed 's/^/diag - /' "$tmp/lowercase.out"; }

# Headings are prose. Casing, trailing colons and deeper levels are all the same
# answer, and rejecting them would make the rule about wording rather than about
# whether the question was answered.
variants="$(fixture variants <<'MD'
# widget-service

### OVERVIEW:
Serves the widget catalogue to the storefront and keeps its search index warm.

#### Maintainers
Owned by the platform team; contact #verjson-platform or open an issue here.

## Getting started
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
)"
check "$variants" >"$tmp/variants.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "heading case, depth and trailing punctuation do not change the answer" \
  || { fail "an equivalent heading spelling was rejected (rc=$rc)"; sed 's/^/diag - /' "$tmp/variants.out"; }

# Non-ASCII prose is prose. A byte-vs-character mix-up in the substance floor
# would quietly hold non-English READMEs to a shorter or longer bar than English.
unicode="$(fixture unicode <<'MD'
# gestión-de-widgets

## Propósito
Sirve el catálogo de widgets a la tienda y mantiene su índice de búsqueda.

## Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation
Ejecuta `npm ci && npm test` antes de subir; `npm run dev` arranca en :3000.
MD
)"
check "$unicode" >"$tmp/unicode.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a heading outside the documented alias list is still a finding" \
  || { fail "an untranslated alias silently satisfied the purpose topic (rc=$rc)"; sed 's/^/diag - /' "$tmp/unicode.out"; }

unicode_ok="$(fixture unicode-ok <<'MD'
# gestión-de-widgets

## Purpose
Sirve el catálogo de widgets a la tienda y mantiene su índice de búsqueda.

## Ownership
Equipo de plataforma; escríbenos en #verjson-platform o abre una incidencia.

## Local validation
Ejecuta `npm ci && npm test` antes de subir; `npm run dev` arranca en :3000.
MD
)"
check "$unicode_ok" >"$tmp/unicode-ok.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "non-ASCII prose counts toward the substance floor" \
  || { fail "unicode body measured against the wrong floor (rc=$rc)"; sed 's/^/diag - /' "$tmp/unicode-ok.out"; }

# A section whose only content is a heading of its own has no answer under it.
runon="$(fixture runon <<'MD'
# widget-service

## Purpose
## Ownership
## Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
)"
check "$runon" >"$tmp/runon.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && pass "a heading immediately followed by the next heading has no answer" \
  || { fail "empty section accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/runon.out"; }

# --------------------------------------------------------------------------
# Workflow contract. The script's guarantees only hold if the workflow runs the
# CENTRAL copy of it against the CONSUMER's tree — running the consumer's copy
# would hand the audited repository the check that audits it.
# --------------------------------------------------------------------------
wf="$repo_root/.github/workflows/repo-hygiene.yml"
if [ ! -f "$wf" ]; then
  fail "no reusable hygiene workflow at .github/workflows/repo-hygiene.yml"
else
  grep -qE '^  workflow_call:' "$wf" \
    && pass "the hygiene check ships as one reusable workflow, not a copied job" \
    || fail "repo-hygiene.yml is not callable as a reusable workflow"

  # Audit by default: landing this cannot turn any consumer's CI red on day one.
  # Enforcement is a per-caller opt-in and an org decision, not a side effect.
  mode_default="$(awk '/^      mode:/{f=1} f && /default:/{print; exit}' "$wf")"
  grep -qF "'audit'" <<<"$mode_default" \
    && pass "the mode input defaults to audit, so rollout cannot break consumers" \
    || fail "repo-hygiene.yml does not default to audit mode (got: ${mode_default:-none})"

  # Single quotes are deliberate throughout this block: these are literal
  # workflow fragments to match, not shell expansions. (shellcheck SC2016)
  # shellcheck disable=SC2016
  grep -qF 'repository: Verjson/.github' "$wf" \
    && grep -qF 'ref: ${{ inputs.hygiene_ref }}' "$wf" \
    && pass "the workflow checks out the central repository at a caller-pinned ref" \
    || fail "repo-hygiene.yml does not check out the central repository at a pinned ref"

  # The invocation must name the central checkout path. A bare
  # `scripts/repo-hygiene.sh` would resolve inside the consumer's tree.
  grep -qE 'bash \.repo-hygiene/scripts/repo-hygiene\.sh' "$wf" \
    && pass "the workflow runs the central script, not the consumer's copy of it" \
    || fail "repo-hygiene.yml does not run the script from the central checkout"

  # Through the environment rather than interpolated into the script body — the
  # house rule for every expansion that reaches a `run:` block.
  # shellcheck disable=SC2016
  { grep -qF 'HYGIENE_REPOSITORY: ${{ github.repository }}' "$wf" \
    && grep -qF -- '--repository "$HYGIENE_REPOSITORY"' "$wf"; } \
    && pass "the workflow identifies the audited repository for the register" \
    || fail "repo-hygiene.yml does not pass the audited repository through the environment"

  # shellcheck disable=SC2016
  grep -qF -- '--repo-root "$GITHUB_WORKSPACE"' "$wf" \
    && pass "the workflow audits the consumer's checked-out tree" \
    || fail "repo-hygiene.yml does not point the check at the consumer tree"
fi

# Wired, or it does not run. That gap once left hold.test.sh dormant.
grep -qF 'bash scripts/repo-hygiene.test.sh' "$repo_root/.github/workflows/actions-ci.yml" \
  && pass "this suite is wired into actions-ci" \
  || fail "repo-hygiene.test.sh is not wired into actions-ci.yml — it would never run"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
